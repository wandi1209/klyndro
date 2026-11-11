import Foundation

/// What this device advertises about itself in `hello`.
public struct LocalDeviceInfo: Sendable, Equatable {
    public var deviceID: DeviceID
    public var name: String
    public var platform: Platform
    public var appVersion: String
    public var capabilities: [Capability]
    public var fingerprint: Fingerprint

    public init(
        deviceID: DeviceID,
        name: String,
        platform: Platform,
        appVersion: String,
        capabilities: [Capability],
        fingerprint: Fingerprint
    ) {
        self.deviceID = deviceID
        self.name = name
        self.platform = platform
        self.appVersion = appVersion
        self.capabilities = capabilities
        self.fingerprint = fingerprint
    }

    func helloBody(nonce: Nonce) -> HelloBody {
        HelloBody(
            deviceID: deviceID,
            deviceName: name,
            platform: platform,
            appVersion: appVersion,
            protocolVersion: Envelope.currentVersion,
            capabilities: capabilities,
            nonce: nonce
        )
    }
}

/// The authenticated peer, as established by the handshake.
public struct PeerSessionInfo: Sendable, Equatable {
    public var deviceID: DeviceID
    public var name: String
    public var platform: Platform
    public var appVersion: String
    public var capabilities: [Capability]
    /// Fingerprint observed from the peer's TLS certificate, not from its claims.
    public var fingerprint: Fingerprint
    /// Capabilities both sides support.
    public var negotiated: [Capability]

    public var supportsClipboard: Bool { negotiated.contains(.clipboard) }
}

public enum PeerSessionEvent: Sendable {
    case established(PeerSessionInfo)
    case message(Envelope)
    case closed(SessionCloseReason)
}

public enum SessionCloseReason: Sendable, Equatable, CustomStringConvertible {
    case local
    case peer
    case heartbeatTimeout
    case handshakeFailed(String)
    case protocolViolation(String)
    case transportFailed(String)

    public var description: String {
        switch self {
        case .local: return "closed locally"
        case .peer: return "closed by peer"
        case .heartbeatTimeout: return "peer stopped responding"
        case .handshakeFailed(let reason): return "handshake failed: \(reason)"
        case .protocolViolation(let reason): return "protocol violation: \(reason)"
        case .transportFailed(let reason): return "transport failed: \(reason)"
        }
    }
}

public enum SessionError: Error, Equatable, Sendable, CustomStringConvertible {
    case notStarted
    case notEstablished
    case selfConnection
    case unexpectedMessageBeforeHandshake(String)
    case peerReportedError(String)
    case transportDoesNotExposePeerKey

    var closeReason: SessionCloseReason {
        switch self {
        case .peerReportedError(let code): return .protocolViolation("peer error \(code)")
        case .transportDoesNotExposePeerKey: return .handshakeFailed("peer key unavailable")
        default: return .handshakeFailed(description)
        }
    }

    public var description: String {
        switch self {
        case .notStarted: return "session was not started"
        case .notEstablished: return "session is not authenticated"
        case .selfConnection: return "peer presented this device's own identifier"
        case .unexpectedMessageBeforeHandshake(let type): return "received \(type) before handshake"
        case .peerReportedError(let code): return "peer reported \(code)"
        case .transportDoesNotExposePeerKey: return "the transport did not expose the peer key"
        }
    }
}

/// Owns one authenticated session: handshake, heartbeat, and message dispatch.
///
/// Transport-agnostic on purpose. The same type is driven by `NWFrameTransport` in the app and
/// by an in-memory transport in tests, which is where the timing and violation rules are proven.
public actor PeerSession {
    public enum Role: Sendable {
        /// The side that opened the TCP connection.
        case initiator
        /// The side that accepted it.
        case responder
    }

    private struct HandshakeProgress {
        let localNonce: Nonce
        var remoteHello: HelloBody?
        var acknowledgementSent = false
        var acknowledgementReceived = false

        var isComplete: Bool {
            guard remoteHello != nil else { return false }
            return acknowledgementSent || acknowledgementReceived
        }
    }

    private let transport: FrameTransport
    private let local: LocalDeviceInfo
    private let role: Role
    private let heartbeatInterval: Duration
    private let deadAfter: TimeInterval
    private let handshakeTimeout: Duration

    private var continuation: AsyncStream<PeerSessionEvent>.Continuation?
    private var eventStream: AsyncStream<PeerSessionEvent>?
    private var lastActivity = Date()
    private var isRunning = false
    private var isEstablished = false
    private var progress: HandshakeProgress?

    public init(
        transport: FrameTransport,
        local: LocalDeviceInfo,
        role: Role,
        heartbeatInterval: Duration = .seconds(15),
        deadAfter: TimeInterval = 45,
        handshakeTimeout: Duration = .seconds(10)
    ) {
        self.transport = transport
        self.local = local
        self.role = role
        self.heartbeatInterval = heartbeatInterval
        self.deadAfter = deadAfter
        self.handshakeTimeout = handshakeTimeout
    }

    /// Events for this session.
    ///
    /// Idempotent: repeated calls return the same stream. Replacing the continuation would leave
    /// the caller holding a stream that never receives anything, which is a silent, hard-to-find
    /// failure — an `AsyncStream` is single-consumer and cannot simply be fanned out.
    public func events() -> AsyncStream<PeerSessionEvent> {
        if let eventStream { return eventStream }
        let (stream, continuation) = AsyncStream<PeerSessionEvent>.makeStream()
        self.continuation = continuation
        self.eventStream = stream
        return stream
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { await self.run() }
    }

    /// Sends an envelope, refusing when the session is not yet authenticated.
    public func send(_ envelope: Envelope) async throws {
        guard isEstablished else { throw SessionError.notEstablished }
        try await transport.send(try EnvelopeCodec.frame(for: envelope))
    }

    public func close() {
        transport.close()
    }

    // MARK: - Lifecycle

    private func run() async {
        let handshake = HandshakeProgress(localNonce: Nonce())
        progress = handshake

        let deadline = Task { [handshakeTimeout] in
            try? await Task.sleep(for: handshakeTimeout)
            await self.abortIfHandshaking()
        }

        var heartbeat: Task<Void, Never>?
        // `nil` means "no reason recorded yet"; the default is applied after the loop so a
        // violation recorded inside it is not overwritten.
        var recordedReason: SessionCloseReason?

        do {
            try await sendHello(nonce: handshake.localNonce)

            receiveLoop: for try await frame in transport.incoming() {
                lastActivity = Date()
                let envelope = try EnvelopeCodec.decode(frame: frame)

                if !isEstablished {
                    if let info = try await absorbHandshakeFrame(envelope) {
                        isEstablished = true
                        deadline.cancel()
                        emit(.established(info))
                        heartbeat = Task { await self.runHeartbeat() }
                    }
                    continue
                }

                switch envelope.messageType {
                case .ping:
                    let nonce = envelope.bodyField("nonce")?.stringValue ?? ""
                    try await sendPong(nonce: nonce)

                case .pong:
                    break

                case .pairRequest, .pairConfirm, .pairResult:
                    recordedReason = .protocolViolation("pairing message on an authenticated session")
                    break receiveLoop

                case .hello, .helloAck:
                    recordedReason = .protocolViolation("handshake restart on an established session")
                    break receiveLoop

                default:
                    emit(.message(envelope))
                }
            }

            recordedReason = recordedReason ?? (isEstablished
                ? .peer
                : .handshakeFailed("peer closed before authenticating"))

        } catch let error as SessionError {
            recordedReason = error.closeReason
        } catch let error as ProtocolError {
            recordedReason = .protocolViolation(error.description)
        } catch let error as HandshakeError {
            recordedReason = .handshakeFailed(error.description)
        } catch let error as PairingMessageError {
            recordedReason = .protocolViolation(error.description)
        } catch let error as TransportError {
            recordedReason = error.isClosed
                ? (isEstablished ? .peer : .handshakeFailed("connection closed during handshake"))
                : .transportFailed(error.description)
        } catch is CancellationError {
            recordedReason = .local
        } catch {
            recordedReason = .transportFailed(String(describing: error))
        }

        deadline.cancel()
        heartbeat?.cancel()
        isEstablished = false
        progress = nil
        transport.close()
        emit(.closed(recordedReason ?? .peer))
        continuation?.finish()
    }

    /// Advances the handshake by one message. Returns session info on completion.
    private func absorbHandshakeFrame(_ envelope: Envelope) async throws -> PeerSessionInfo? {
        guard var progress else { throw SessionError.notStarted }

        switch envelope.messageType {
        case .hello:
            let hello = try HandshakeCodec.decodeHello(envelope)
            guard hello.deviceID != local.deviceID else { throw SessionError.selfConnection }
            progress.remoteHello = hello

            if role == .responder, !progress.acknowledgementSent {
                try await transport.send(
                    try EnvelopeCodec.frame(
                        for: HandshakeCodec.helloAckEnvelope(
                            HelloAckBody(
                                hello: local.helloBody(nonce: Nonce()),
                                echoNonce: hello.nonce
                            )
                        )
                    )
                )
                progress.acknowledgementSent = true
            }

        case .helloAck:
            let ack = try HandshakeCodec.decodeHelloAck(envelope)
            if progress.remoteHello == nil {
                progress.remoteHello = ack.hello
                if ack.hello.deviceID == local.deviceID {
                    throw SessionError.selfConnection
                }
            }
            try HandshakeCodec.verify(ack: ack, expectedEcho: progress.localNonce)
            progress.acknowledgementReceived = true

        case .error:
            throw SessionError.peerReportedError(
                envelope.bodyField("code")?.stringValue ?? "unknown"
            )

        default:
            throw SessionError.unexpectedMessageBeforeHandshake(envelope.type)
        }

        self.progress = progress
        guard progress.isComplete, let remote = progress.remoteHello else { return nil }

        let fingerprint = try observedFingerprint()
        let negotiated = Capability.negotiate(local: local.capabilities, remote: remote.capabilities)

        return PeerSessionInfo(
            deviceID: remote.deviceID,
            name: remote.deviceName,
            platform: remote.platform,
            appVersion: remote.appVersion,
            capabilities: remote.capabilities,
            fingerprint: fingerprint,
            negotiated: negotiated
        )
    }

    private func sendHello(nonce: Nonce) async throws {
        try await transport.send(
            try EnvelopeCodec.frame(for: HandshakeCodec.helloEnvelope(local.helloBody(nonce: nonce)))
        )
    }

    private func sendPong(nonce: String) async throws {
        try await transport.send(
            try EnvelopeCodec.frame(
                for: Envelope(type: .pong, body: .object(["nonce": .string(nonce)]))
            )
        )
    }

    private func runHeartbeat() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: heartbeatInterval)
            if Task.isCancelled { return }

            if Date().timeIntervalSince(lastActivity) > deadAfter {
                transport.close()
                return
            }

            try? await transport.send(
                try EnvelopeCodec.frame(
                    for: Envelope(type: .ping, body: .object(["nonce": .string(Nonce().hex)]))
                )
            )
        }
    }

    private func abortIfHandshaking() {
        if !isEstablished {
            transport.close()
        }
    }

    /// The fingerprint comes from the transport's TLS view, never from the peer's claims.
    private func observedFingerprint() throws -> Fingerprint {
        guard let reporting = transport as? PeerKeyReporting, let key = reporting.peerPublicKey else {
            throw SessionError.transportDoesNotExposePeerKey
        }
        return Fingerprint(spki: key)
    }

    private func emit(_ event: PeerSessionEvent) {
        continuation?.yield(event)
    }
}

extension TransportError {
    var isClosed: Bool {
        if case .closed = self { return true }
        return false
    }
}
