import Foundation
@testable import KlyndroKit
import Testing

/// A pasteboard backed by memory, so sync can be tested without touching the real clipboard.
@MainActor
final class FakePasteboard: Pasteboard {
    private(set) var text: String
    private(set) var changeCount: Int
    private(set) var writeCount = 0
    var sensitive = false

    init(text: String = "", changeCount: Int = 0) {
        self.text = text
        self.changeCount = changeCount
    }

    func read() -> ClipboardSnapshot? {
        guard !text.isEmpty else { return nil }
        return ClipboardSnapshot(text: text, sensitive: sensitive, changeCount: changeCount)
    }

    func write(text: String) {
        self.text = text
        changeCount += 1
        writeCount += 1
    }

    /// Simulates the user copying something in another app.
    func userCopies(_ newText: String) {
        text = newText
        changeCount += 1
    }
}

@Suite("Clipboard sync across two peers", .serialized)
@MainActor
struct ClipboardSyncIntegrationTests {
    private struct Peer {
        let session: PeerSession
        let sync: ClipboardSync
        let pasteboard: FakePasteboard
        let events: EventRecorder
    }

    private func makePair(
        allowSensitive: Bool = false
    ) async -> (mac: Peer, phone: Peer, macID: DeviceID, phoneID: DeviceID) {
        let (macTransport, phoneTransport) = FrameTransportLoopback.makePair()
        macTransport.peerPublicKey = Data("phone key".utf8)
        phoneTransport.peerPublicKey = Data("mac key".utf8)

        let macID = DeviceID()
        let phoneID = DeviceID()

        let macSession = PeerSession(
            transport: macTransport,
            local: LocalDeviceInfo(
                deviceID: macID,
                name: "Mac",
                platform: .macos,
                appVersion: "test",
                capabilities: [.clipboard],
                fingerprint: Fingerprint(spki: Data("mac key".utf8))
            ),
            role: .initiator,
            heartbeatInterval: .seconds(60)
        )
        let phoneSession = PeerSession(
            transport: phoneTransport,
            local: LocalDeviceInfo(
                deviceID: phoneID,
                name: "Phone",
                platform: .android,
                appVersion: "test",
                capabilities: [.clipboard],
                fingerprint: Fingerprint(spki: Data("phone key".utf8))
            ),
            role: .responder,
            heartbeatInterval: .seconds(60)
        )

        let macPasteboard = FakePasteboard()
        let phonePasteboard = FakePasteboard()

        let macSync = ClipboardSync(
            deviceID: macID,
            pasteboard: macPasteboard,
            monitor: nil,
            session: macSession,
            isEnabled: true,
            allowsSensitive: allowSensitive
        )
        let phoneSync = ClipboardSync(
            deviceID: phoneID,
            pasteboard: phonePasteboard,
            monitor: nil,
            session: phoneSession,
            isEnabled: true,
            allowsSensitive: allowSensitive
        )

        return (
            Peer(session: macSession, sync: macSync, pasteboard: macPasteboard, events: EventRecorder()),
            Peer(session: phoneSession, sync: phoneSync, pasteboard: phonePasteboard, events: EventRecorder()),
            macID,
            phoneID
        )
    }

    /// Wires each session's messages into the other side's clipboard sync, then connects.
    private func run(
        _ pair: (mac: Peer, phone: Peer, macID: DeviceID, phoneID: DeviceID)
    ) async {
        let macEvents = await pair.mac.session.events()
        let phoneEvents = await pair.phone.session.events()

        // One consumer per stream: an AsyncStream cannot be iterated twice without splitting the
        // events, so the recorder and the clipboard bridge share a single loop each.
        Task { [macSync = pair.mac.sync, recorder = pair.mac.events] in
            for await event in macEvents {
                await recorder.record(event)
                guard case .message(let envelope) = event,
                      envelope.messageType == .clipboardUpdate,
                      let body = try? ClipboardMessageCodec.decodeUpdate(envelope) else { continue }
                await macSync.remoteClipboardChanged(body, refID: envelope.id)
            }
        }
        Task { [phoneSync = pair.phone.sync, recorder = pair.phone.events] in
            for await event in phoneEvents {
                await recorder.record(event)
                guard case .message(let envelope) = event,
                      envelope.messageType == .clipboardUpdate,
                      let body = try? ClipboardMessageCodec.decodeUpdate(envelope) else { continue }
                await phoneSync.remoteClipboardChanged(body, refID: envelope.id)
            }
        }

        await pair.mac.session.start()
        await pair.phone.session.start()
        _ = await pollUntilMain {
            let macReady = await pair.mac.events.established() != nil
            let phoneReady = await pair.phone.events.established() != nil
            return macReady && phoneReady
        }

        pair.mac.sync.start()
        pair.phone.sync.start()
    }

    @Test("text copied on the laptop arrives on the phone")
    func macToPhone() async {
        let pair = await makePair()
        await run(pair)

        pair.mac.pasteboard.userCopies("hello from the mac")
        await pair.mac.sync.localClipboardChanged(pair.mac.pasteboard.read()!)

        let arrived = await pollUntilMain {
            pair.phone.pasteboard.text == "hello from the mac"
        }
        #expect(arrived, "the phone must receive the laptop's clipboard")
        #expect(pair.phone.sync.appliedCount == 1)
        #expect(pair.mac.sync.sentCount == 1)
    }

    @Test("text copied on the phone arrives on the laptop")
    func phoneToMac() async {
        let pair = await makePair()
        await run(pair)

        pair.phone.pasteboard.userCopies("hello from the phone")
        await pair.phone.sync.localClipboardChanged(pair.phone.pasteboard.read()!)

        let arrived = await pollUntilMain {
            pair.mac.pasteboard.text == "hello from the phone"
        }
        #expect(arrived, "the laptop must receive the phone's clipboard")
        #expect(pair.mac.sync.appliedCount == 1)
    }

    @Test("applying remote content never loops back to the sender")
    func noLoop() async {
        let pair = await makePair()
        await run(pair)

        pair.mac.pasteboard.userCopies("ping")
        await pair.mac.sync.localClipboardChanged(pair.mac.pasteboard.read()!)
        _ = await pollUntilMain { pair.phone.pasteboard.text == "ping" }

        // Now simulate what a pasteboard monitor would do on the phone after applying: it sees a
        // local change and tries to send it back. The engine must refuse.
        pair.phone.pasteboard.userCopies("ping")
        await pair.phone.sync.localClipboardChanged(pair.phone.pasteboard.read()!)

        try? await Task.sleep(for: .milliseconds(200))

        #expect(pair.phone.sync.sentCount == 0, "the receiver must not echo the content back")
        #expect(pair.mac.pasteboard.text == "ping", "the laptop's clipboard must be unchanged")
        #expect(pair.mac.sync.appliedCount == 0, "no round trip may reach the laptop again")
    }

    @Test("a burst of changes converges without duplicates")
    func burstConverges() async {
        let pair = await makePair()
        await run(pair)

        for index in 1...5 {
            pair.mac.pasteboard.userCopies("item \(index)")
            await pair.mac.sync.localClipboardChanged(pair.mac.pasteboard.read()!)
        }

        let arrived = await pollUntilMain { pair.phone.pasteboard.text == "item 5" }
        #expect(arrived)
        #expect(pair.mac.sync.sentCount == 5)
        // Each item is applied once; the final text is the last one sent.
        #expect(pair.phone.sync.appliedCount == 5)
    }

    @Test("sensitive content is not sent by default")
    func sensitiveNotSent() async {
        let pair = await makePair(allowSensitive: false)
        await run(pair)

        pair.mac.pasteboard.userCopies("correct horse battery staple")
        pair.mac.pasteboard.sensitive = true
        await pair.mac.sync.localClipboardChanged(pair.mac.pasteboard.read()!)

        try? await Task.sleep(for: .milliseconds(200))
        #expect(pair.mac.sync.sentCount == 0)
        #expect(pair.phone.pasteboard.text != "correct horse battery staple")
    }

    @Test("sensitive content is sent when the user allows it")
    func sensitiveSentWhenAllowed() async {
        let pair = await makePair(allowSensitive: true)
        await run(pair)

        pair.mac.pasteboard.userCopies("allowed secret")
        pair.mac.pasteboard.sensitive = true
        await pair.mac.sync.localClipboardChanged(pair.mac.pasteboard.read()!)

        let arrived = await pollUntilMain { pair.phone.pasteboard.text == "allowed secret" }
        #expect(arrived)
    }

    @Test("disabling sync stops both directions")
    func disablingStopsSync() async {
        let pair = await makePair()
        await run(pair)

        pair.mac.sync.setEnabled(false)
        pair.phone.sync.setEnabled(false)

        pair.mac.pasteboard.userCopies("should not travel")
        await pair.mac.sync.localClipboardChanged(pair.mac.pasteboard.read()!)

        try? await Task.sleep(for: .milliseconds(200))
        #expect(pair.phone.pasteboard.text != "should not travel")
    }
}
