import Foundation
import Testing
@testable import KlyndroKit

@Suite("Mirror input codec")
struct MirrorInputCodecTests {

    @Test("round trips tap, swipe, and action envelopes")
    func roundTripsInputMessages() throws {
        let tap = InputGestureBody(kind: .tap, x: 0.25, y: 0.75)
        #expect(try #require(InputGestureBody.decode(tap.toEnvelope())) == tap)

        let swipe = InputGestureBody(kind: .swipe, x: 0.5, y: 0.8, endX: 0.5, endY: 0.2, durationMs: 220)
        #expect(try #require(InputGestureBody.decode(swipe.toEnvelope())) == swipe)

        let action = InputActionBody(action: .home)
        #expect(try #require(InputActionBody.decode(action.toEnvelope())) == action)
    }

    @Test("rejects out-of-range coordinates, bad durations, and incomplete swipes")
    func rejectsInvalidInput() {
        let badCoord = Envelope(type: .inputGesture, body: .object([
            "kind": .string("tap"),
            "x": .number(1.2),
            "y": .number(0.5),
            "duration_ms": .number(50)
        ]))
        #expect(InputGestureBody.decode(badCoord) == nil)

        let incompleteSwipe = Envelope(type: .inputGesture, body: .object([
            "kind": .string("swipe"),
            "x": .number(0.5),
            "y": .number(0.8),
            "duration_ms": .number(200)
        ]))
        #expect(InputGestureBody.decode(incompleteSwipe) == nil)

        let unknownAction = Envelope(type: .inputAction, body: .object(["action": .string("reboot")]))
        #expect(InputActionBody.decode(unknownAction) == nil)
    }

    @Test("round trips input.text and rejects oversized or empty append")
    func roundTripsInputText() throws {
        let append = InputTextBody(mode: .append, text: "hello")
        #expect(try #require(InputTextBody.decode(append.toEnvelope())) == append)

        let backspace = InputTextBody(mode: .backspace, text: "")
        #expect(try #require(InputTextBody.decode(backspace.toEnvelope())) == backspace)

        let emptyAppend = InputTextBody(mode: .append, text: "")
        #expect(InputTextBody.decode(emptyAppend.toEnvelope()) == nil)

        let huge = InputTextBody(mode: .replace, text: String(repeating: "a", count: InputTextBody.maxUTF8Bytes + 1))
        #expect(InputTextBody.decode(huge.toEnvelope()) == nil)
    }

    @Test("round trips app.list and app.launch and filters bad entries")
    func roundTripsAppLauncherMessages() throws {
        let e1 = try #require(StandardAppEntry(package: "id.my.wandidev.klyndro", label: "Klyndro"))
        let e2 = try #require(StandardAppEntry(package: "com.whatsapp", label: "WhatsApp"))
        let listEnv = AppLauncherMessages.listEnvelope(apps: [e2, e1])
        let decodedList = try #require(AppLauncherMessages.decodeList(listEnv))
        #expect(decodedList == [e1, e2])

        let launchEnv = AppLauncherMessages.launchEnvelope(package: e1.package)
        #expect(try #require(AppLauncherMessages.decodeLaunch(launchEnv)) == e1.package)

        let badLaunch = Envelope(type: .appLaunch, body: .object(["package": .string("bad;rm")]))
        #expect(AppLauncherMessages.decodeLaunch(badLaunch) == nil)
    }
}
