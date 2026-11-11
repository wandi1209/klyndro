import Foundation
import Network
import Security

/// TLS 1.3 configuration shared by the listener and the dialer.
///
/// Trust is decided *only* by `PinPolicy`. `SecTrustEvaluate` is deliberately not consulted:
/// every Klyndro certificate is self-signed, so system evaluation would reject all of them,
/// and what we actually trust is a previously pinned public key (protocol §2, ADR 0002).
public enum TLSConfigurator {
    public static func parameters(
        identity: DeviceIdentity,
        policy: PinPolicy,
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(options, true)

        if let secIdentity = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(options, secIdentity)
        }

        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            complete(policy.evaluate(peerTrust: secTrust).isAccepted)
        }, queue)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10

        return NWParameters(tls: tls, tcp: tcp)
    }
}

extension PinPolicy {
    /// Adapter that pulls the leaf certificate out of a `SecTrust` and applies the policy.
    /// Lives here because it needs Security types; the decision itself stays in `PinPolicy`.
    func evaluate(peerTrust trust: SecTrust) -> PinDecision {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return .rejected(.unparsableCertificate)
        }
        return evaluate(peerCertificateDER: SecCertificateCopyData(leaf) as Data)
    }
}

/// A Network.framework TCP+TLS connection exposed as a frame transport.
public final class NWFrameTransport: FrameTransport, PeerKeyReporting, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var stream: AsyncThrowingStream<Frame, Error>?
    private var continuation: AsyncThrowingStream<Frame, Error>.Continuation?
    /// Frames that arrived before anyone asked for the stream. TLS can go ready and the peer's
    /// `hello` can arrive before `PeerSession` subscribes; dropping it would strand the handshake.
    private var pendingFrames: [Frame] = []
    private var pendingError: Error?
    private var closedFlag = false
    private var receiveStarted = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Address the peer connected from, when the endpoint is a host/port pair.
    ///
    /// Recorded in the trust store so the Mac can later dial the phone if that is ever needed;
    /// today the phone always initiates.
    public var remoteEndpoint: (host: String, port: UInt16)? {
        guard case let .hostPort(host, port) = connection.endpoint else { return nil }
        return ("\(host)", port.rawValue)
    }

    /// Peer public key (DER SubjectPublicKeyInfo) as observed by the TLS layer.
    ///
    /// Read after the handshake, so it reflects what the peer actually proved possession of,
    /// not what a TXT record claimed.
    public var peerPublicKey: Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition)
            as? NWProtocolTLS.Metadata else { return nil }
        guard let key = sec_protocol_metadata_copy_peer_public_key(metadata.securityProtocolMetadata)
        else { return nil }
        NSLog("[tls] peer key bytes=%d", (key as AnyObject as? Data)?.count ?? -1)
        // `dispatch_data_t` bridges to `Data` through `AnyObject`; a direct `as Data` does not
        // compile against this SDK. Exercised by the TLS loopback test.
        return key as AnyObject as? Data
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = LockedFlag()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumed.runOnce { continuation.resume() }
                case .failed(let error):
                    resumed.runOnce {
                        continuation.resume(throwing: TransportError.failed(String(describing: error)))
                    }
                case .cancelled:
                    resumed.runOnce {
                        continuation.resume(throwing: TransportError.closed)
                    }
                case .waiting(let error):
                    // A waiting TLS connection usually means the peer rejected our certificate.
                    resumed.runOnce {
                        continuation.resume(throwing: TransportError.failed(String(describing: error)))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        startReceiving()
    }

    /// Starts a connection vended by `NWListener`.
    ///
    /// Network.framework does not start accepted connections for you: without this, the peer's
    /// TLS ClientHello has nothing to complete against and the socket resets.
    public func startAccepted() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = LockedFlag()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumed.runOnce { continuation.resume() }
                case .failed(let error):
                    resumed.runOnce {
                        continuation.resume(throwing: TransportError.failed(String(describing: error)))
                    }
                case .cancelled:
                    resumed.runOnce {
                        continuation.resume(throwing: TransportError.closed)
                    }
                case .waiting(let error):
                    resumed.runOnce {
                        continuation.resume(throwing: TransportError.failed(String(describing: error)))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        startReceiving()
    }

    public func send(_ frame: Frame) async throws {
        let isClosed = lock.withLock { closedFlag }
        guard !isClosed else { throw TransportError.closed }

        let data: Data
        do {
            data = try FrameEncoder.encode(frame)
        } catch {
            throw TransportError.failed(String(describing: error))
        }

        // Fire-and-forget on purpose. TCP preserves order, and a per-send completion that never
        // fires on cancellation leaks its continuation; failures surface through the receive
        // stream and the connection state handler instead.
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error, let self else { return }
            self.finish(throwing: TransportError.failed(String(describing: error)))
        })
    }

    public func incoming() -> AsyncThrowingStream<Frame, Error> {
        lock.lock()
        if let stream {
            lock.unlock()
            return stream
        }
        let pending = pendingFrames
        pendingFrames.removeAll()
        let error = pendingError
        let closed = closedFlag

        let stream = AsyncThrowingStream<Frame, Error> { continuation in
            self.continuation = continuation
        }
        self.stream = stream
        lock.unlock()

        for frame in pending { continuation?.yield(frame) }
        if let error { continuation?.finish(throwing: error) }
        else if closed { continuation?.finish() }
        return stream
    }

    public func close() {
        lock.lock()
        guard !closedFlag else {
            lock.unlock()
            return
        }
        closedFlag = true
        let continuation = self.continuation
        lock.unlock()

        connection.cancel()
        continuation?.finish()
    }

    // MARK: - Receiving

    private func startReceiving() {
        lock.lock()
        guard !receiveStarted else {
            lock.unlock()
            return
        }
        receiveStarted = true
        lock.unlock()
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                do {
                    try self.consume(data)
                } catch {
                    self.finish(throwing: error)
                    return
                }
            }

            if let error {
                self.finish(throwing: TransportError.failed(String(describing: error)))
                return
            }

            if isComplete {
                self.finish(throwing: nil)
                return
            }

            self.receiveNext()
        }
    }

    private func consume(_ data: Data) throws {
        lock.lock()
        decoder.append(data)
        var frames: [Frame] = []
        var failure: Error?
        while true {
            do {
                guard let frame = try decoder.nextFrame() else { break }
                frames.append(frame)
            } catch {
                failure = error
                break
            }
        }
        let continuation = self.continuation
        let buffered = continuation == nil
        lock.unlock()

        if buffered {
            lock.lock()
            pendingFrames.append(contentsOf: frames)
            lock.unlock()
        } else {
            for frame in frames { continuation?.yield(frame) }
        }
        if let failure { throw failure }
    }

    private func finish(throwing error: Error?) {
        lock.lock()
        guard !closedFlag else {
            lock.unlock()
            return
        }
        closedFlag = true
        pendingError = error
        let continuation = self.continuation
        lock.unlock()

        connection.cancel()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}

/// Accepts connections with mutual TLS.
public final class KlyndroListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let onConnection: @Sendable (NWFrameTransport) -> Void

    public private(set) var port: UInt16?

    public init(
        identity: DeviceIdentity,
        policy: PinPolicy,
        service: NWListener.Service? = nil,
        port: NWEndpoint.Port = .any,
        queue: DispatchQueue = DispatchQueue(label: "id.my.wandidev.klyndro.listener"),
        onConnection: @escaping @Sendable (NWFrameTransport) -> Void
    ) throws {
        let parameters = TLSConfigurator.parameters(identity: identity, policy: policy)
        parameters.allowLocalEndpointReuse = true

        self.listener = try NWListener(using: parameters, on: port)
        self.queue = queue
        self.onConnection = onConnection
        // Advertised once the port is bound; `NWListener` accepts a service after `.ready`.
        self.listener.service = service
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = LockedFlag()

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = self.listener.port?.rawValue {
                        self.port = port
                    }
                    resumed.runOnce { continuation.resume() }
                case .failed(let error):
                    resumed.runOnce {
                        continuation.resume(throwing: TransportError.failed(String(describing: error)))
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [queue, onConnection] connection in
                let transport = NWFrameTransport(connection: connection, queue: queue)
                Task {
                    do {
                        try await transport.startAccepted()
                        onConnection(transport)
                    } catch {
                        transport.close()
                    }
                }
            }

            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
    }
}

/// Wraps a socket connection with framing and bounded timeouts.
public enum KlyndroDialer {
    /// Connects, completes the TLS handshake, and returns a ready transport.
    public static func connect(
        host: String,
        port: UInt16,
        identity: DeviceIdentity,
        policy: PinPolicy,
        timeout: TimeInterval = 10
    ) async throws -> NWFrameTransport {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.failed("invalid port \(port)")
        }

        let parameters = TLSConfigurator.parameters(identity: identity, policy: policy)
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )
        let queue = DispatchQueue(label: "id.my.wandidev.klyndro.dialer")
        let transport = NWFrameTransport(connection: connection, queue: queue)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await transport.start() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw TransportError.timedOut("TLS handshake")
            }
            try await group.next()
            group.cancelAll()
        }
        return transport
    }
}

/// Small helper so a state handler can resume a continuation at most once.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func runOnce(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !used
        used = true
        lock.unlock()
        if shouldRun { body() }
    }
}
