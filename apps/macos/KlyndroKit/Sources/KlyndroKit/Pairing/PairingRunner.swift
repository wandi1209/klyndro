import Foundation

/// What a device needs to run a pairing attempt.
public struct PairingLocalInfo: Sendable, Equatable {
    public var deviceID: DeviceID
    public var name: String
    public var platform: Platform
    public var capabilities: [Capability]
    public var fingerprint: Fingerprint

    public init(
        deviceID: DeviceID,
        name: String,
        platform: Platform,
        capabilities: [Capability],
        fingerprint: Fingerprint
    ) {
        self.deviceID = deviceID
        self.name = name
        self.platform = platform
        self.capabilities = capabilities
        self.fingerprint = fingerprint
    }

    func request(nonce: Nonce) -> PairRequestBody {
        PairRequestBody(
            deviceID: deviceID,
            deviceName: name,
            platform: platform,
            fingerprint: fingerprint,
            nonce: nonce,
            protocolVersion: Envelope.currentVersion,
            capabilities: capabilities
        )
    }
}

public enum PairingEvent: Sendable {
    /// Both devices must show these digits and the user must confirm on both.
    case awaitingConfirmation(code: String, peerName: String)
    case paired(TrustedPeer)
    case failed(PairingFailure)
}

/// Runs one pairing attempt over an already-established TLS connection.
///
/// Security-relevant detail: the peer's *claimed* fingerprint is never trusted on its own. It is
/// compared with the key the TLS layer observed for this connection, so a device cannot claim
/// somebody else's identity (see protocol §7).
public actor PairingRunner {
    public enum Role: Sendable {
        case initiator
        case responder
    }

    private let transport: FrameTransport
    private let local: PairingLocalInfo
    private let role: Role
    private let trustStore: TrustStore
    private let window: PairingWindow
    private let peerHost: String?
    private let peerPort: Int?

    private var continuation: AsyncStream<PairingEvent>.Continuation?
    private var localNonce = Nonce()
    private var attempt: PairingAttempt?
    private var peerFingerprintFromTLS: Fingerprint?
    private var isFinished = false
    private var confirmedLocally = false
    private var peerConfirmed = false

    public init(
        transport: FrameTransport,
        local: PairingLocalInfo,
        role: Role,
        trustStore: TrustStore,
        window: PairingWindow,
        peerHost: String? = nil,
        peerPort: Int? = nil
    ) {
        self.transport = transport
        self.local = local
        self.role = role
        self.trustStore = trustStore
        self.window = window
        self.peerHost = peerHost
        self.peerPort = peerPort
    }

    public func events() -> AsyncStream<PairingEvent> {
        let (stream, continuation) = AsyncStream<PairingEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    public func start() {
        Task { await self.run() }
    }

    /// The user on this device accepted the digits.
    public func confirm() async {
        guard !isFinished, let attempt else { return }
        confirmedLocally = true
        try? await send(.confirm, body: attempt.confirmBody().jsonValue)
        if peerConfirmed {
            await persistAndFinish(with: attempt)
        }
    }

    /// The user on this device rejected the digits.
    public func reject() async {
        guard !isFinished else { return }
        await finish(
            .failed(.userRejected),
            result: PairResultBody(accepted: false, reason: .userRejected)
        )
    }

    // MARK: - Flow

    private func run() async {
        do {
            // The pairing window bounds every attempt, including the handshake.
            guard window.isOpen() else {
                await finish(.failed(.windowClosed), result: nil)
                return
            }

            // Fresh TLS view of the peer. Retry briefly if TLS metadata hasn't populated yet.
            guard let reporting = transport as? PeerKeyReporting else {
                await finish(.failed(.internalError), result: nil)
                return
            }

            var peerKey: Data? = reporting.peerPublicKey
            if peerKey == nil {
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if let k = reporting.peerPublicKey {
                        peerKey = k
                        break
                    }
                }
            }

            guard let key = peerKey else {
                await finish(.failed(.internalError), result: nil)
                return
            }
            peerFingerprintFromTLS = Fingerprint(spki: key)

            if role == .initiator {
                try await sendRequest()
            }

            for try await frame in transport.incoming() {
                let envelope = try EnvelopeCodec.decode(frame: frame)
                switch envelope.messageType {
                case .pairRequest:
                    try await handleRequest(PairingMessageCodec.decodeRequest(envelope))
                case .pairConfirm:
                    try await handleConfirm(PairingMessageCodec.decodeConfirm(envelope))
                case .pairResult:
                    let result = try PairingMessageCodec.decodeResult(envelope)
                    if !result.accepted {
                        await finish(.failed(result.reason ?? .internalError), result: nil)
                    }
                default:
                    // Pairing sessions carry pairing messages only.
                    await finish(.failed(.internalError), result: nil)
                }
            }

            if !isFinished {
                await finish(.failed(.windowClosed), result: nil)
            }
        } catch let error as PairingValidationError {
            _ = error
            await finish(.failed(.sasMismatch), result: PairResultBody(accepted: false, reason: .sasMismatch))
        } catch is PairingWindowError {
            await finish(.failed(.windowClosed), result: PairResultBody(accepted: false, reason: .windowClosed))
        } catch {
            await finish(.failed(.internalError), result: nil)
        }
    }

    private func handleRequest(_ request: PairRequestBody) async throws {
        // The claimed fingerprint must match the key TLS actually saw for this connection.
        guard let tlsFingerprint = peerFingerprintFromTLS,
              request.fingerprint.matches(tlsFingerprint) else {
            await finish(.failed(.sasMismatch), result: PairResultBody(accepted: false, reason: .sasMismatch))
            return
        }

        if role == .responder {
            try await sendRequest()
        }

        guard attempt == nil else { return }

        // One runner == one attempt. Counting attempts across connections is the caller's job
        // (`PairingWindow.beginAttempt`), because the window outlives a single connection.
        guard window.isOpen() else {
            await finish(.failed(.windowClosed), result: PairResultBody(accepted: false, reason: .windowClosed))
            return
        }

        let attempt = PairingAttempt(
            remote: request,
            localFingerprint: local.fingerprint,
            localNonce: localNonce
        )
        self.attempt = attempt
        continuation?.yield(.awaitingConfirmation(code: attempt.code.digits, peerName: request.deviceName))
    }

    private func handleConfirm(_ confirm: PairConfirmBody) async throws {
        guard let attempt else {
            await finish(.failed(.internalError), result: nil)
            return
        }

        do {
            try attempt.validate(confirm)
        } catch let error as PairingValidationError {
            _ = error
            await finish(.failed(.sasMismatch), result: PairResultBody(accepted: false, reason: .sasMismatch))
            return
        }

        peerConfirmed = true

        // Both sides must have shown the code to a human before anything is persisted.
        guard confirmedLocally else {
            // The peer confirmed first; wait for this device's user.
            return
        }

        await persistAndFinish(with: attempt)
    }

    private func persistAndFinish(with attempt: PairingAttempt) async {
        let peer = attempt.trustedPeer(host: peerHost, port: peerPort)
        do {
            try trustStore.upsert(peer)
        } catch {
            await finish(.failed(.internalError), result: PairResultBody(accepted: false, reason: .internalError))
            return
        }

        try? await send(.result, body: PairResultBody(accepted: true).jsonValue)
        await finish(.paired(peer), result: nil)
    }

    private func sendRequest() async throws {
        try await send(.request, body: local.request(nonce: localNonce).jsonValue)
    }

    private enum Outgoing { case request, confirm, result }

    private func send(_ kind: Outgoing, body: JSONValue) async throws {
        let envelope: Envelope
        switch kind {
        case .request:
            envelope = Envelope(type: .pairRequest, body: body)
        case .confirm:
            envelope = Envelope(type: .pairConfirm, body: body)
        case .result:
            envelope = Envelope(type: .pairResult, body: body)
        }
        try await transport.send(try EnvelopeCodec.frame(for: envelope))
    }

    private func finish(_ event: PairingEvent, result: PairResultBody?) async {
        guard !isFinished else { return }
        isFinished = true
        if let result {
            try? await send(.result, body: result.jsonValue)
        }
        continuation?.yield(event)
        continuation?.finish()
        transport.close()
    }
}
