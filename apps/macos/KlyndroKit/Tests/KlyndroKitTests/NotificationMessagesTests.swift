import Foundation
import Testing
@testable import KlyndroKit

@Suite("Notification messages codec")
struct NotificationMessagesTests {
    private func sample() -> NotificationPostBody {
        NotificationPostBody(
            key: "com.example.chat:100:1762800000",
            package: "com.example.chat",
            appName: "ChatApp",
            title: "Alice",
            text: "Hello from phone!",
            postedAt: 1762800000,
            sensitive: false
        )
    }

    @Test("round trips notification.post through envelope")
    func roundTrip() throws {
        let original = sample()
        let envelope = try NotificationMessageCodec.postEnvelope(original)
        #expect(envelope.messageType == .notificationPost)

        let decoded = try NotificationMessageCodec.decodePost(envelope)
        #expect(decoded == original)
    }

    @Test("fixture conformance: decodes notification-post.json")
    func fixtureConformance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KlyndroKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // KlyndroKit
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent() // repo root
        let fixtureURL = root.appendingPathComponent("protocol/fixtures/notification-post.json")

        guard let data = try? Data(contentsOf: fixtureURL) else {
            Issue.record("could not read notification-post.json at \(fixtureURL.path)")
            return
        }

        let env = try EnvelopeCodec.decode(payload: data)
        let post = try NotificationMessageCodec.decodePost(env)
        #expect(post.package == "com.example.messenger")
        #expect(post.appName == "Example Messenger")
        #expect(post.title == "Fixture notification")
        #expect(post.sensitive == false)
    }

    @Test("rejects oversized title")
    func rejectsOversizedTitle() {
        let longTitle = String(repeating: "A", count: 1025)
        var body = sample()
        body.title = longTitle
        #expect(throws: NotificationMessageError.self) {
            _ = try NotificationMessageCodec.postEnvelope(body)
        }
    }

    @Test("rejects oversized text")
    func rejectsOversizedText() {
        let longText = String(repeating: "T", count: 8193)
        var body = sample()
        body.text = longText
        #expect(throws: NotificationMessageError.self) {
            _ = try NotificationMessageCodec.postEnvelope(body)
        }
    }

    @Test("refuses to decode non-notification envelope")
    func refusesNonNotificationEnvelope() {
        let env = Envelope(type: .ping, body: nil)
        #expect(throws: NotificationMessageError.self) {
            _ = try NotificationMessageCodec.decodePost(env)
        }
    }
}
