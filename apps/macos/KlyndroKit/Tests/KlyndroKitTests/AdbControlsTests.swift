import Foundation
import Testing
@testable import KlyndroKit

@Suite("ADB controls")
struct AdbControlsTests {

    @Test("validates package names strictly and rejects shell/flag injection")
    func validatesPackageNames() {
        #expect(AdbPackageName("id.my.wandidev.klyndro")?.value == "id.my.wandidev.klyndro")
        #expect(AdbPackageName("com.whatsapp")?.value == "com.whatsapp")

        let bad = [
            "",
            "singleword",
            "-p",
            "com.example;rm -rf /",
            "com.example..bad",
            "com.example/MainActivity",
            "com.example\n"
        ]
        for raw in bad where !raw.hasSuffix("\n") {
            #expect(AdbPackageName(raw) == nil, "should reject '\(raw)'")
        }
    }

    @Test("parses pm list packages output cleanly and sorts")
    func parsesPackagesOutput() {
        let sample = """
        package:com.whatsapp
        package:id.my.wandidev.klyndro
        package:com.whatsapp
        package:bad;injection
        junk line
        """
        let parsed = AdbPackagesParser.parse(sample).map(\.value)
        #expect(parsed == ["com.whatsapp", "id.my.wandidev.klyndro"])
    }

    @Test("builds safe argument arrays for keyevent, launch, and screencap")
    func buildsArgumentArrays() throws {
        let pkg = try #require(AdbPackageName("id.my.wandidev.klyndro"))
        #expect(AdbControlCommand.keyEventArguments(serial: "abc123", key: .recents) == [
            "-s", "abc123", "shell", "input", "keyevent", "KEYCODE_APP_SWITCH"
        ])
        #expect(AdbControlCommand.launchPackageArguments(serial: "abc123", package: pkg) == [
            "-s", "abc123", "shell", "monkey", "-p", "id.my.wandidev.klyndro", "-c", "android.intent.category.LAUNCHER", "1"
        ])
        #expect(AdbControlCommand.screencapArguments(serial: "abc123") == [
            "-s", "abc123", "exec-out", "screencap", "-p"
        ])
    }
}
