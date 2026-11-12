import Foundation
import Testing
@testable import KlyndroKit

@Suite("Wireless adb")
struct WirelessAdbTests {
    @Test("accepts a well-formed IPv4 endpoint")
    func validEndpoint() {
        let endpoint = AdbEndpoint(address: "192.168.66.63:37171")
        #expect(endpoint?.host == "192.168.66.63")
        #expect(endpoint?.port == 37171)
        #expect(endpoint?.address == "192.168.66.63:37171")
    }

    @Test("rejects anything that is not a plain IPv4 host and port", arguments: [
        "", "192.168.66.63", "192.168.66.63:0", "192.168.66.63:99999", "192.168.66.256:5555",
        "192.168.66:5555", "-s:5555", "--help:5555", "host.local:5555", "192.168.66.63:abc",
        "192.168.66.63:5555 -x", "1.2.3.4.5:5555", "1..3.4:5555", "::1:5555",
    ])
    func invalidEndpoint(_ raw: String) {
        #expect(AdbEndpoint(address: raw) == nil)
    }

    @Test("pairing code is exactly six ASCII digits")
    func pairingCode() {
        #expect(AdbPairingCode("356879")?.value == "356879")
        #expect(AdbPairingCode(" 356879 ")?.value == "356879")
        for bad in ["", "12345", "1234567", "12345a", "-12345", "１２３４５６"] {
            #expect(AdbPairingCode(bad) == nil)
        }
    }

    @Test("adb connect output is classified")
    func connectOutput() {
        #expect(AdbWirelessParser.parseConnect("connected to 192.168.66.63:37171\n")
            == .success("connected to 192.168.66.63:37171"))
        #expect(AdbWirelessParser.parseConnect("already connected to 192.168.66.63:37171")
            == .success("already connected to 192.168.66.63:37171"))
        #expect(AdbWirelessParser.parseConnect("failed to connect to '192.168.66.63:37171': No route to host")
            == .failure("failed to connect to '192.168.66.63:37171': No route to host"))
        #expect(AdbWirelessParser.parseConnect("* daemon started successfully\nconnected to 10.0.0.2:5555")
            == .success("connected to 10.0.0.2:5555"))
        #expect(AdbWirelessParser.parseConnect("") == .failure("adb printed nothing"))
    }

    @Test("adb pair output is classified")
    func pairOutput() {
        #expect(AdbWirelessParser.parsePair("Successfully paired to 192.168.66.63:34705 [guid=adb-x]")
            == .success("Successfully paired to 192.168.66.63:34705 [guid=adb-x]"))
        #expect(AdbWirelessParser.parsePair("error: protocol fault (couldn't read status message): Undefined error: 0")
            == .failure("error: protocol fault (couldn't read status message): Undefined error: 0"))
        #expect(AdbWirelessParser.parsePair("Failed: Wrong password or connection was dropped.")
            == .failure("Failed: Wrong password or connection was dropped."))
    }

    @Test("a hung tool is killed at the timeout")
    func processTimeout() {
        let output = AdbProcess.run("/bin/sleep", ["30"], timeout: 0.5)
        #expect(output.timedOut)
    }

    @Test("a missing tool reports a launch failure instead of crashing")
    func missingTool() {
        let output = AdbProcess.run("/nonexistent/adb", ["devices"])
        #expect(output.status == -1)
        #expect(output.text.contains("could not launch"))
    }

    @Test("output of a quick tool is captured")
    func capturesOutput() {
        let output = AdbProcess.run("/bin/echo", ["hello"])
        #expect(output.status == 0)
        #expect(output.text.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(!output.timedOut)
    }
}
