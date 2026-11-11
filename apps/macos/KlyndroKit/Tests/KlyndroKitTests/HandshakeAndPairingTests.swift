import Foundation
@testable import KlyndroKit
import Testing

@Suite("Session handshake")
struct HandshakeTests {
    private let nonce = Nonce(hex: String(repeating: "ab", count: 16))!
    private let deviceID = DeviceID(hex: "a1b2c3d4e5f60718")!

    private func localBody(
        capabilities: [Capability] = [.clipboard, .notifications],
        name: String = "Test Android"
    ) -> HelloBody {
        HelloBody(
            deviceID: deviceID,
            deviceName: name,
            platform: .android,
            appVersion: "0.1.0",
            capabilities: capabilities,
            nonce: nonce
        )
    }

    @Test("round trips hello through JSON")
    func helloRoundTrip() throws {
        let envelope = HandshakeCodec.helloEnvelope(localBody())
        let decoded = try HandshakeCodec.decodeHello(envelope)

        #expect(decoded.deviceID == deviceID)
        #expect(decoded.deviceName == "Test Android")
        #expect(decoded.platform == .android)
        #expect(decoded.protocolVersion == 1)
        #expect(decoded.capabilities == [.clipboard, .notifications])
        #expect(decoded.nonce.hex == nonce.hex)
    }

    @Test("round trips hello.ack and keeps the echo nonce")
    func ackRoundTrip() throws {
        let ack = HelloAckBody(hello: localBody(), echoNonce: nonce)
        let decoded = try HandshakeCodec.decodeHelloAck(HandshakeCodec.helloAckEnvelope(ack))

        #expect(decoded.echoNonce.hex == nonce.hex)
        #expect(decoded.hello.deviceID == deviceID)
    }

    @Test("rejects a missing field, naming it")
    func rejectsMissingField() throws {
        var body = localBody().jsonValue
        guard case .object(var fields) = body else {
            Issue.record("expected an object")
            return
        }
        fields["device_name"] = nil
        body = .object(fields)

        let envelope = Envelope(type: .hello, body: body)
        #expect(throws: HandshakeError.missingField("device_name")) {
            _ = try HandshakeCodec.decodeHello(envelope)
        }
    }

    @Test("rejects an invalid device id")
    func rejectsInvalidDeviceID() {
        let envelope = Envelope(
            type: .hello,
            body: .object([
                "device_id": .string("too-short"),
                "device_name": .string("x"),
                "platform": .string("android"),
                "app_version": .string("1"),
                "protocol_version": .number(1),
                "capabilities": .array([]),
                "nonce": .string(nonce.hex)
            ])
        )
        #expect(throws: HandshakeError.invalidField("device_id")) {
            _ = try HandshakeCodec.decodeHello(envelope)
        }
    }

    @Test("rejects an unknown platform and an unsupported version")
    func rejectsUnknownPlatformAndVersion() {
        let badPlatform = Envelope(
            type: .hello,
            body: .object([
                "device_id": .string(deviceID.hex),
                "device_name": .string("x"),
                "platform": .string("windows"),
                "app_version": .string("1"),
                "protocol_version": .number(1),
                "capabilities": .array([]),
                "nonce": .string(nonce.hex)
            ])
        )
        #expect(throws: HandshakeError.invalidField("platform")) {
            _ = try HandshakeCodec.decodeHello(badPlatform)
        }

        let futureVersion = Envelope(
            type: .hello,
            body: .object([
                "device_id": .string(deviceID.hex),
                "device_name": .string("x"),
                "platform": .string("macos"),
                "app_version": .string("1"),
                "protocol_version": .number(2),
                "capabilities": .array([]),
                "nonce": .string(nonce.hex)
            ])
        )
        #expect(throws: HandshakeError.unsupportedProtocolVersion(2)) {
            _ = try HandshakeCodec.decodeHello(futureVersion)
        }
    }

    @Test("rejects an oversized device name")
    func rejectsOversizedName() {
        let envelope = Envelope(
            type: .hello,
            body: .object([
                "device_id": .string(deviceID.hex),
                "device_name": .string(String(repeating: "x", count: 257)),
                "platform": .string("android"),
                "app_version": .string("1"),
                "protocol_version": .number(1),
                "capabilities": .array([]),
                "nonce": .string(nonce.hex)
            ])
        )
        #expect(throws: HandshakeError.invalidField("device_name")) {
            _ = try HandshakeCodec.decodeHello(envelope)
        }
    }

    @Test("refuses to read hello.ack as hello")
    func rejectsWrongType() {
        let envelope = Envelope(type: .pairRequest, body: localBody().jsonValue)
        #expect {
            _ = try HandshakeCodec.decodeHello(envelope)
        } throws: { error in
            guard case HandshakeError.wrongMessageType = error else { return false }
            return true
        }
    }

    @Test("detects a replayed acknowledgement")
    func detectsReplay() throws {
        let otherNonce = Nonce()
        let ack = HelloAckBody(hello: localBody(), echoNonce: otherNonce)

        #expect(throws: HandshakeError.nonceEchoMismatch) {
            try HandshakeCodec.verify(ack: ack, expectedEcho: nonce)
        }
    }

    @Test("ignores unknown capabilities but keeps known ones")
    func unknownCapabilitiesIgnored() {
        let parsed = Capability.parse(["clipboard", "teleportation", "mirroring"])
        #expect(parsed == [.clipboard, .mirroring])
    }

    @Test("negotiation is the intersection in a stable order")
    func negotiation() {
        let negotiated = Capability.negotiate(
            local: [.presence, .clipboard, .mirroring],
            remote: [.mirroring, .presence, .fileTransfer]
        )
        #expect(negotiated == [.mirroring, .presence], "file-transfer is not offered locally, so it cannot be negotiated")
    }
}

@Suite("Pairing messages")
struct PairingMessageTests {
    private let fingerprint = Fingerprint(spki: Data("peer key".utf8))
    private let nonce = Nonce()

    private func request() -> PairRequestBody {
        PairRequestBody(
            deviceID: DeviceID(hex: "a1b2c3d4e5f60718")!,
            deviceName: "Phone",
            platform: .android,
            fingerprint: fingerprint,
            nonce: nonce,
            capabilities: [.clipboard]
        )
    }

    @Test("round trips pair.request")
    func requestRoundTrip() throws {
        let decoded = try PairingMessageCodec.decodeRequest(
            PairingMessageCodec.requestEnvelope(request())
        )
        #expect(decoded == request())
    }

    @Test("round trips pair.confirm")
    func confirmRoundTrip() throws {
        let body = PairConfirmBody(
            fingerprint: fingerprint,
            nonce: nonce,
            sasDigest: Fingerprint(spki: Data("digest".utf8))
        )
        let decoded = try PairingMessageCodec.decodeConfirm(
            PairingMessageCodec.confirmEnvelope(body)
        )
        #expect(decoded == body)
    }

    @Test("round trips pair.result with and without a reason")
    func resultRoundTrip() throws {
        let accepted = try PairingMessageCodec.decodeResult(
            PairingMessageCodec.resultEnvelope(PairResultBody(accepted: true))
        )
        #expect(accepted == PairResultBody(accepted: true, reason: nil))

        let refused = try PairingMessageCodec.decodeResult(
            PairingMessageCodec.resultEnvelope(
                PairResultBody(accepted: false, reason: .sasMismatch)
            )
        )
        #expect(refused == PairResultBody(accepted: false, reason: .sasMismatch))
    }

    @Test("rejects a malformed fingerprint")
    func rejectsBadFingerprint() {
        var body = request().jsonValue
        guard case .object(var fields) = body else { return }
        fields["fingerprint"] = .string("abc")
        body = .object(fields)

        #expect(throws: PairingMessageError.invalidField("fingerprint")) {
            _ = try PairingMessageCodec.decodeRequest(Envelope(type: .pairRequest, body: body))
        }
    }

    @Test("refuses to decode a non-pairing message")
    func rejectsForeignType() {
        #expect(throws: PairingMessageError.notAPairingMessage(.ping)) {
            _ = try PairingMessageCodec.decodeRequest(Envelope(type: .ping, body: nil))
        }
    }
}

@Suite("Pairing window and attempt")
struct PairingAttemptTests {
    private let fingerprintA = Fingerprint(spki: Data("device a".utf8))
    private let fingerprintB = Fingerprint(spki: Data("device b".utf8))

    private func request(fingerprint: Fingerprint, nonce: Nonce = Nonce()) -> PairRequestBody {
        PairRequestBody(
            deviceID: DeviceID(hex: "a1b2c3d4e5f60718")!,
            deviceName: "Phone",
            platform: .android,
            fingerprint: fingerprint,
            nonce: nonce,
            capabilities: [.clipboard]
        )
    }

    @Test("the window closes after its duration")
    func windowExpiry() {
        let opened = Date()
        let window = PairingWindow(openedAt: opened, duration: 60)

        #expect(window.isOpen(at: opened))
        #expect(window.isOpen(at: opened.addingTimeInterval(59.9)))
        #expect(!window.isOpen(at: opened.addingTimeInterval(60)))
        #expect(!window.isOpen(at: opened.addingTimeInterval(-1)), "clock going backwards is not open")
        #expect(window.remaining(at: opened.addingTimeInterval(30)) == 30)
        #expect(window.remaining(at: opened.addingTimeInterval(90)) == 0)
    }

    @Test("the fourth attempt in a window is refused")
    func rateLimit() throws {
        let opened = Date()
        var window = PairingWindow(openedAt: opened, duration: 60, maxAttempts: 3)

        for attempt in 1...3 {
            try window.beginAttempt(at: opened.addingTimeInterval(1))
            #expect(window.attempts == attempt)
        }
        #expect(throws: PairingWindowError.rateLimited) {
            try window.beginAttempt(at: opened.addingTimeInterval(2))
        }
    }

    @Test("an attempt after expiry is refused")
    func attemptAfterExpiry() {
        var window = PairingWindow(openedAt: Date(), duration: 0.001)
        #expect(throws: PairingWindowError.windowClosed) {
            try window.beginAttempt(at: Date().addingTimeInterval(1))
        }
    }

    @Test("both devices compute the same code and confirmations validate")
    func happyPath() throws {
        let macFingerprint = fingerprintA
        let androidFingerprint = fingerprintB
        let androidRequest = request(fingerprint: androidFingerprint)

        let macAttempt = PairingAttempt(
            remote: androidRequest,
            localFingerprint: macFingerprint,
            localNonce: Nonce()
        )

        // The Android side computes its own view from the Mac's request.
        let macNonce = macAttempt.localNonce
        let macRequest = request(fingerprint: macFingerprint, nonce: macNonce)
        let androidAttempt = PairingAttempt(
            remote: macRequest,
            localFingerprint: androidFingerprint,
            localNonce: androidRequest.nonce
        )

        #expect(macAttempt.code.digits == androidAttempt.code.digits)
        #expect(macAttempt.code.digest.matches(androidAttempt.code.digest))

        try macAttempt.validate(androidAttempt.confirmBody())
        try androidAttempt.validate(macAttempt.confirmBody())

        let record = macAttempt.trustedPeer(host: "192.0.2.10", port: 47_823)
        #expect(record.deviceID == androidRequest.deviceID.hex)
        #expect(record.fingerprint == androidFingerprint.hex)
        #expect(record.lastPort == 47_823)
    }

    @Test("a swapped fingerprint fails even though the code looks plausible")
    func rejectsSwappedFingerprint() {
        let androidRequest = request(fingerprint: fingerprintB)
        let attempt = PairingAttempt(
            remote: androidRequest,
            localFingerprint: fingerprintA,
            localNonce: Nonce()
        )

        // Simulates an active MITM presenting a different key on the second leg.
        let forged = PairConfirmBody(
            fingerprint: fingerprintA,
            nonce: androidRequest.nonce,
            sasDigest: attempt.code.digest
        )

        #expect(throws: PairingValidationError.fingerprintMismatch) {
            try attempt.validate(forged)
        }
    }

    @Test("a wrong digest is rejected")
    func rejectsWrongDigest() {
        let androidRequest = request(fingerprint: fingerprintB)
        let attempt = PairingAttempt(
            remote: androidRequest,
            localFingerprint: fingerprintA,
            localNonce: Nonce()
        )

        let forged = PairConfirmBody(
            fingerprint: fingerprintB,
            nonce: androidRequest.nonce,
            sasDigest: Fingerprint(spki: Data("other digest".utf8))
        )

        #expect(throws: PairingValidationError.digestMismatch) {
            try attempt.validate(forged)
        }
    }

    @Test("a wrong nonce echo is rejected")
    func rejectsWrongNonce() {
        let androidRequest = request(fingerprint: fingerprintB)
        let attempt = PairingAttempt(
            remote: androidRequest,
            localFingerprint: fingerprintA,
            localNonce: Nonce()
        )

        let forged = PairConfirmBody(
            fingerprint: fingerprintB,
            nonce: Nonce(),
            sasDigest: attempt.code.digest
        )

        #expect(throws: PairingValidationError.nonceMismatch) {
            try attempt.validate(forged)
        }
    }
}
