import Foundation
@testable import KlyndroKit
import Testing

@Suite("Clipboard messages")
struct ClipboardMessageTests {
    private let deviceID = DeviceID(hex: "a1b2c3d4e5f60718")!
    private let origin = DeviceID(hex: "0011223344556677")!

    private func update(
        text: String = "hello",
        changeCount: Int = 1,
        sensitive: Bool = false
    ) -> ClipboardUpdateBody {
        ClipboardUpdateBody(
            text: text,
            hash: ClipboardMessageCodec.hash(of: text),
            changeCount: changeCount,
            originID: origin,
            sensitive: sensitive
        )
    }

    @Test("hash is SHA-256 of the UTF-8 text")
    func hashIsStable() {
        // Known-value check: SHA-256("abc") is a fixed, widely published digest.
        #expect(ClipboardMessageCodec.hash(of: "abc")
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ClipboardMessageCodec.hash(of: "").count == 64)
    }

    @Test("the shared fixture's hash matches this implementation")
    func fixtureHashMatches() throws {
        // Both suites read the same fixture. If the two hash implementations diverged, loop
        // suppression would fail silently across platforms rather than loudly in a test.
        var url = URL(filePath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let file = url.appending(path: "protocol/fixtures/clipboard-update.json")
        let data = try Data(contentsOf: file)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try #require(object["body"] as? [String: Any])
        let text = try #require(body["text"] as? String)
        let hash = try #require(body["hash"] as? String)

        #expect(ClipboardMessageCodec.hash(of: text) == hash)
    }

    @Test("round trips an update")
    func updateRoundTrip() throws {
        let body = update(text: "klyndro", changeCount: 7, sensitive: true)
        let decoded = try ClipboardMessageCodec.decodeUpdate(
            ClipboardMessageCodec.updateEnvelope(body)
        )
        #expect(decoded == body)
    }

    @Test("round trips an ack with and without a reason")
    func ackRoundTrip() throws {
        let accepted = ClipboardAckBody(refID: "ref-1", accepted: true)
        #expect(try ClipboardMessageCodec.decodeAck(
            ClipboardMessageCodec.ackEnvelope(accepted)
        ) == accepted)

        let refused = ClipboardAckBody(refID: "ref-2", accepted: false, reason: .tooLarge)
        #expect(try ClipboardMessageCodec.decodeAck(
            ClipboardMessageCodec.ackEnvelope(refused)
        ) == refused)
    }

    @Test("rejects an unsupported content type")
    func rejectsUnsupportedType() {
        let envelope = Envelope(
            type: .clipboardUpdate,
            body: .object([
                "content_type": .string("image/png"),
                "text": .string("x"),
                "hash": .string(String(repeating: "a", count: 64)),
                "change_count": .number(1),
                "origin_id": .string(origin.hex),
                "sensitive": .bool(false)
            ])
        )
        #expect(throws: ClipboardMessageError.invalidField("content_type")) {
            _ = try ClipboardMessageCodec.decodeUpdate(envelope)
        }
    }

    @Test("rejects content over 256 KiB, counting bytes not characters")
    func rejectsOversizedContent() {
        // 131 072 CJK characters occupy 3 bytes each: under the character limit, over the byte limit.
        let cjk = String(repeating: "東", count: 131_072)
        #expect(cjk.count < ClipboardMessageCodec.maximumTextBytes)

        let envelope = Envelope(
            type: .clipboardUpdate,
            body: .object([
                "content_type": .string("text/plain"),
                "text": .string(cjk),
                "hash": .string(ClipboardMessageCodec.hash(of: cjk)),
                "change_count": .number(1),
                "origin_id": .string(origin.hex),
                "sensitive": .bool(false)
            ])
        )
        #expect(throws: ClipboardMessageError.self) {
            _ = try ClipboardMessageCodec.decodeUpdate(envelope)
        }
    }

    @Test("rejects a malformed hash, counter or origin")
    func rejectsMalformedFields() {
        func envelope(_ mutate: (inout [String: JSONValue]) -> Void) -> Envelope {
            var fields: [String: JSONValue] = [
                "content_type": .string("text/plain"),
                "text": .string("x"),
                "hash": .string(String(repeating: "a", count: 64)),
                "change_count": .number(1),
                "origin_id": .string(origin.hex),
                "sensitive": .bool(false)
            ]
            mutate(&fields)
            return Envelope(type: .clipboardUpdate, body: .object(fields))
        }

        #expect(throws: ClipboardMessageError.invalidField("hash")) {
            _ = try ClipboardMessageCodec.decodeUpdate(envelope { $0["hash"] = .string("abc") })
        }
        #expect(throws: ClipboardMessageError.invalidField("change_count")) {
            _ = try ClipboardMessageCodec.decodeUpdate(envelope { $0["change_count"] = .number(-1) })
        }
        #expect(throws: ClipboardMessageError.invalidField("origin_id")) {
            _ = try ClipboardMessageCodec.decodeUpdate(envelope { $0["origin_id"] = .string("short") })
        }
    }

    @Test("refuses to read a non-clipboard message")
    func rejectsForeignType() {
        #expect(throws: ClipboardMessageError.self) {
            _ = try ClipboardMessageCodec.decodeUpdate(Envelope(type: .ping, body: nil))
        }
    }
}

@Suite("Clipboard sync engine")
struct ClipboardSyncEngineTests {
    private let macID = DeviceID(hex: "aaaaaaaaaaaaaaaa")!
    private let phoneID = DeviceID(hex: "bbbbbbbbbbbbbbbb")!
    private let start = Date(timeIntervalSince1970: 1_762_800_000)

    private func snapshot(_ text: String, count: Int, sensitive: Bool = false) -> ClipboardSnapshot {
        ClipboardSnapshot(text: text, sensitive: sensitive, changeCount: count)
    }

    private func remote(_ text: String, count: Int, from: DeviceID? = nil, sensitive: Bool = false) -> ClipboardUpdateBody {
        ClipboardUpdateBody(
            text: text,
            hash: ClipboardMessageCodec.hash(of: text),
            changeCount: count,
            originID: from ?? phoneID,
            sensitive: sensitive
        )
    }

    @Test("sends new local content exactly once")
    func sendsNewContent() {
        var engine = ClipboardSyncEngine(deviceID: macID)

        guard case .send(let body) = engine.outbound(snapshot("hello", count: 1), now: start) else {
            Issue.record("expected a send")
            return
        }
        #expect(body.text == "hello")
        #expect(body.originID == macID)
        #expect(body.changeCount == 1)
        #expect(body.hash == ClipboardMessageCodec.hash(of: "hello"))

        // Polling the same platform change again must not resend.
        #expect(engine.outbound(snapshot("hello", count: 1), now: start) == .suppress(.duplicate))
    }

    @Test("increments the change counter per send")
    func changeCounterIncrements() {
        var engine = ClipboardSyncEngine(deviceID: macID)
        _ = engine.outbound(snapshot("one", count: 1), now: start)
        _ = engine.outbound(snapshot("two", count: 2), now: start)
        #expect(engine.currentChangeCounter == 2)
    }

    @Test("suppresses everything while disabled")
    func respectsDisabled() {
        var engine = ClipboardSyncEngine(deviceID: macID, isEnabled: false)
        #expect(engine.outbound(snapshot("hello", count: 1), now: start) == .suppress(.disabled))

        var applied = engine.inbound(remote("hello", count: 1), now: start)
        #expect(applied == .ignore(.disabled))
        applied = engine.inbound(remote("hello", count: 1), now: start)
        #expect(applied == .ignore(.disabled))
    }

    @Test("does not send sensitive content unless allowed")
    func sensitiveGateOutbound() {
        var engine = ClipboardSyncEngine(deviceID: macID)
        #expect(engine.outbound(snapshot("secret", count: 1, sensitive: true), now: start)
            == .suppress(.sensitive))

        var permissive = ClipboardSyncEngine(deviceID: macID, allowsSensitive: true)
        guard case .send(let body) = permissive.outbound(
            snapshot("secret", count: 1, sensitive: true),
            now: start
        ) else {
            Issue.record("expected a send when sensitive sync is allowed")
            return
        }
        #expect(body.sensitive)
    }

    @Test("does not apply sensitive content unless allowed")
    func sensitiveGateInbound() {
        var engine = ClipboardSyncEngine(deviceID: macID)
        #expect(engine.inbound(remote("secret", count: 1, sensitive: true), now: start)
            == .ignore(.sensitive))

        var permissive = ClipboardSyncEngine(deviceID: macID, allowsSensitive: true)
        #expect(permissive.inbound(remote("secret", count: 1, sensitive: true), now: start)
            == .apply("secret"))
    }

    @Test("refuses to send content over the size limit")
    func sizeLimitOutbound() {
        var engine = ClipboardSyncEngine(deviceID: macID)
        let big = String(repeating: "a", count: ClipboardMessageCodec.maximumTextBytes + 1)
        #expect(engine.outbound(snapshot(big, count: 1), now: start) == .suppress(.tooLarge))
    }

    @Test("ignores its own content coming back")
    func ignoresOwnOrigin() {
        var engine = ClipboardSyncEngine(deviceID: macID)
        let echo = remote("mine", count: 1, from: macID)
        #expect(engine.inbound(echo, now: start) == .ignore(.ownOrigin))
    }

    @Test("applies remote content once and ignores the duplicate")
    func appliesRemoteOnce() {
        var engine = ClipboardSyncEngine(deviceID: macID)

        #expect(engine.inbound(remote("from phone", count: 1), now: start) == .apply("from phone"))
        #expect(engine.inbound(remote("from phone", count: 1), now: start) == .ignore(.duplicate)
            || engine.inbound(remote("from phone", count: 1), now: start) == .ignore(.stale))
    }

    @Test("the classic loop terminates: remote applied, echo suppressed")
    func loopIsSuppressed() {
        var engine = ClipboardSyncEngine(deviceID: macID)

        // 1. The phone sends text; we apply it to the pasteboard.
        let inbound = remote("ping-pong", count: 1)
        #expect(engine.inbound(inbound, now: start) == .apply("ping-pong"))
        engine.noteApplied(inbound, at: start)

        // 2. Our pasteboard monitor immediately sees that write. It must not send it back.
        let echo = engine.outbound(snapshot("ping-pong", count: 42), now: start.addingTimeInterval(0.4))
        #expect(echo == .suppress(.echoOfRemote), "the echo of remote content must not be sent back")

        // 3. Even long after the window, the same text is not re-sent (duplicate rule).
        let later = engine.outbound(snapshot("ping-pong", count: 43), now: start.addingTimeInterval(60))
        #expect(later == .suppress(.duplicate))

        // 4. The engine still works for genuinely new content.
        guard case .send = engine.outbound(
            snapshot("something else", count: 44),
            now: start.addingTimeInterval(61)
        ) else {
            Issue.record("new content must still be sent")
            return
        }
    }

    @Test("a stale update from before a reconnect is ignored")
    func rejectsStale() {
        var engine = ClipboardSyncEngine(deviceID: macID)

        #expect(engine.inbound(remote("newer", count: 5), now: start) == .apply("newer"))
        #expect(engine.inbound(remote("older", count: 3), now: start) == .ignore(.stale))
        #expect(engine.inbound(remote("same", count: 5), now: start) == .ignore(.stale))
    }

    @Test("a reconnect does not re-send unchanged content")
    func resetDoesNotResend() {
        var engine = ClipboardSyncEngine(deviceID: macID)
        _ = engine.outbound(snapshot("mine", count: 1), now: start)

        engine.resetSessionState()

        // The pasteboard still holds the text both sides already have.
        #expect(engine.outbound(snapshot("mine", count: 1), now: start) == .suppress(.duplicate))
    }

    @Test("a reconnect clears per-origin staleness")
    func resetClearsStaleness() {
        var engine = ClipboardSyncEngine(deviceID: macID)
        #expect(engine.inbound(remote("theirs", count: 5), now: start) == .apply("theirs"))
        #expect(engine.inbound(remote("older", count: 3), now: start) == .ignore(.stale))

        engine.resetSessionState()

        // Counters are session state: the peer restarts its own counter after reconnecting.
        #expect(engine.inbound(remote("older", count: 3), now: start) == .apply("older"))
    }

    @Test("re-copying older text after other content is a genuine new copy")
    func recopyIsNotSuppressed() {
        var engine = ClipboardSyncEngine(deviceID: macID)
        _ = engine.outbound(snapshot("first", count: 1), now: start)
        _ = engine.outbound(snapshot("second", count: 2), now: start)

        // The user deliberately copies "first" again. De-duplication is about the *current*
        // pasteboard content, not a permanent blocklist, so this must be sent.
        guard case .send(let body) = engine.outbound(snapshot("first", count: 3), now: start) else {
            Issue.record("re-copying older text must be sent")
            return
        }
        #expect(body.text == "first")
    }

    @Test("empty pasteboards are ignored")
    func ignoresEmpty() {
        var engine = ClipboardSyncEngine(deviceID: macID)
        #expect(engine.outbound(snapshot("", count: 1), now: start) == .suppress(.empty))
    }

    @Test("whitespace-only content is still sent")
    func sendsWhitespace() {
        // Copying a single space is a legitimate copy; only genuinely empty text is skipped.
        var engine = ClipboardSyncEngine(deviceID: macID)
        guard case .send = engine.outbound(snapshot(" ", count: 1), now: start) else {
            Issue.record("expected whitespace to be sent")
            return
        }
    }
}
