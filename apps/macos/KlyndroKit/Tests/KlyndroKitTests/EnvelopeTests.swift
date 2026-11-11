import Foundation
import KlyndroKit
import Testing

@Suite("Envelope codec")
struct EnvelopeTests {
    private func payload(_ json: String) -> Data { Data(json.utf8) }

    @Test("encodes the v1 header and omits an absent body")
    func encodesHeaderWithoutBody() throws {
        let envelope = Envelope(id: "3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22", type: .ping, ts: 1_762_800_000_000)
        let payload = try EnvelopeCodec.encode(envelope)
        let object = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )

        #expect(object["v"] as? Int == 1)
        #expect(object["type"] as? String == "ping")
        #expect(object["id"] as? String == "3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22")
        #expect(object["ts"] as? Int64 == 1_762_800_000_000)
        #expect(object["body"] == nil, "an absent body must be omitted, not encoded as null")
    }

    @Test("treats an explicit null body as absent")
    func nullBodyIsOmitted() throws {
        let envelope = Envelope(v: 1, id: UUID().uuidString, type: "ping", ts: 0, body: .null)
        let object = try #require(
            try JSONSerialization.jsonObject(with: EnvelopeCodec.encode(envelope)) as? [String: Any]
        )
        #expect(object["body"] == nil)
    }

    @Test("round trips a body")
    func bodyRoundTrip() throws {
        let body = JSONValue.object([
            "text": .string("hello"),
            "count": .number(3),
            "ok": .bool(true),
            "items": .array([.string("a"), .null])
        ])
        let envelope = Envelope(type: .clipboardUpdate, body: body)
        let decoded = try EnvelopeCodec.decode(payload: EnvelopeCodec.encode(envelope))
        #expect(decoded.body == body)
        #expect(decoded.messageType == .clipboardUpdate)
    }

    @Test("output bytes are stable for identical input")
    func deterministicEncoding() throws {
        let id = "3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22"
        let body = JSONValue.object(["b": .number(2), "a": .number(1)])
        let first = try EnvelopeCodec.encode(Envelope(v: 1, id: id, type: "ping", ts: 5, body: body))
        let second = try EnvelopeCodec.encode(Envelope(v: 1, id: id, type: "ping", ts: 5, body: body))
        #expect(first == second)
    }

    @Test("rejects a missing type")
    func rejectsMissingType() {
        #expect(throws: ProtocolError.self) {
            _ = try EnvelopeCodec.decode(
                payload: payload(#"{"v":1,"id":"3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22","ts":1}"#)
            )
        }
    }

    @Test("rejects a missing id")
    func rejectsMissingId() {
        #expect(throws: ProtocolError.self) {
            _ = try EnvelopeCodec.decode(payload: payload(#"{"v":1,"type":"ping","ts":1}"#))
        }
    }

    @Test("rejects an id that is not a UUID")
    func rejectsNonUUIDIdentifier() {
        #expect(throws: ProtocolError.malformedEnvelope("invalid field 'id'")) {
            _ = try EnvelopeCodec.decode(payload: payload(#"{"v":1,"id":"42","type":"ping","ts":1}"#))
        }
    }

    @Test("rejects a non-integer timestamp")
    func rejectsWrongTimestampType() {
        #expect(throws: ProtocolError.self) {
            _ = try EnvelopeCodec.decode(
                payload: payload(#"{"v":1,"id":"3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22","type":"ping","ts":"soon"}"#)
            )
        }
    }

    @Test("rejects an unsupported envelope version")
    func rejectsFutureVersion() {
        #expect(throws: ProtocolError.unsupportedVersion(2)) {
            _ = try EnvelopeCodec.decode(
                payload: payload(#"{"v":2,"id":"3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22","type":"ping","ts":1}"#)
            )
        }
    }

    @Test("rejects non-object JSON and invalid UTF-8")
    func rejectsGarbage() {
        #expect(throws: ProtocolError.self) {
            _ = try EnvelopeCodec.decode(payload: payload("[1,2,3]"))
        }
        #expect(throws: ProtocolError.self) {
            _ = try EnvelopeCodec.decode(payload: Data([0xFF, 0xFE, 0x00]))
        }
    }

    @Test("classifies unknown types without failing")
    func unknownTypeIsTolerated() throws {
        let decoded = try EnvelopeCodec.decode(
            payload: payload(#"{"v":1,"id":"3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22","type":"future.thing","ts":1}"#)
        )
        #expect(decoded.messageType == .unknown("future.thing"))
        #expect(!decoded.messageType.isKnown)
    }

    @Test("round trips through the frame layer")
    func frameRoundTrip() throws {
        let envelope = Envelope(type: .hello, body: .object(["device_name": .string("Test")]))
        let frame = try EnvelopeCodec.frame(for: envelope)
        #expect(frame.kind == .envelope)
        #expect(try EnvelopeCodec.decode(frame: frame) == envelope)
    }

    @Test("v1 defines exactly one frame kind")
    func singleFrameKind() {
        // File-chunk frames (0x02) arrive with M5. Until then the decoder must reject
        // them rather than guess at a header layout; covered in FrameCodecTests.
        #expect(FrameKind.allCases == [.envelope])
        #expect(throws: ProtocolError.self) {
            _ = try EnvelopeCodec.decode(payload: Data(#"{"v":1,"type":"ping","ts":1}"#.utf8))
        }
    }

    @Test("rejects a payload above the envelope limit")
    func rejectsOversizedPayload() {
        let oversized = Data(repeating: 0x20, count: FramingLimits.maxEnvelopeBytes + 1)
        #expect(throws: ProtocolError.frameTooLarge(FramingLimits.maxEnvelopeBytes + 1)) {
            _ = try EnvelopeCodec.decode(payload: oversized)
        }
    }
}
