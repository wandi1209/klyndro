import Foundation
import Testing
@testable import KlyndroKit

@Suite("adb devices parser")
struct AdbDevicesParserTests {
    @Test("parses a USB device with its model")
    func parsesUSBDevice() {
        let output = """
        List of devices attached
        hiam6hf6lfsshuif       device usb:0-1.3 product:iron_id_global model:2312DRAABG device:iron transport_id:2

        """
        let devices = AdbDevicesParser.parse(output)
        #expect(devices.count == 1)
        #expect(devices[0].serial == "hiam6hf6lfsshuif")
        #expect(devices[0].state == .device)
        #expect(devices[0].model == "2312DRAABG")
        #expect(devices[0].transport == .usb)
        #expect(devices[0].isUsable)
        #expect(devices[0].actionableProblem == nil)
    }

    @Test("a serial with a port is a wireless device")
    func wirelessTransport() {
        let devices = AdbDevicesParser.parse("192.168.1.20:5555\tdevice product:x model:Pixel_8\n")
        #expect(devices.first?.transport == .wireless)
        #expect(devices.first?.model == "Pixel_8")
    }

    @Test("unauthorized and offline devices are not usable and explain themselves")
    func unusableStates() {
        let devices = AdbDevicesParser.parse("""
        List of devices attached
        AAA111 unauthorized usb:1-1 transport_id:3
        BBB222 offline usb:1-2 transport_id:4
        CCC333 recovery usb:1-3 transport_id:5
        """)
        #expect(devices.map(\.state) == [.unauthorized, .offline, .other("recovery")])
        #expect(devices.allSatisfy { !$0.isUsable })
        #expect(devices[0].actionableProblem?.contains("USB debugging") == true)
        #expect(devices[1].actionableProblem?.contains("offline") == true)
        #expect(devices[2].actionableProblem?.contains("recovery") == true)
    }

    @Test("ignores the header, daemon chatter, and blank lines")
    func ignoresNoise() {
        let devices = AdbDevicesParser.parse("""
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached

        """)
        #expect(devices.isEmpty)
    }

    @Test("a device without a model still parses")
    func missingModel() {
        let devices = AdbDevicesParser.parse("ZZZ999 device\n")
        #expect(devices.count == 1)
        #expect(devices[0].model == nil)
    }
}

@Suite("scrcpy command")
struct ScrcpyCommandTests {
    private func make(_ options: MirroringOptions, serial: String = "ABC123", title: String = "Klyndro") -> ScrcpyCommand.Invocation {
        ScrcpyCommand.make(
            scrcpyPath: "/opt/homebrew/bin/scrcpy",
            adbPath: "/sdk/platform-tools/adb",
            serial: serial,
            windowTitle: title,
            options: options
        )
    }

    @Test("defaults are private: no audio, no screen-off, full control")
    func defaults() {
        let invocation = make(.default)
        #expect(invocation.arguments == ["--serial=ABC123", "--window-title=Klyndro", "--no-audio"])
        #expect(invocation.executable == "/opt/homebrew/bin/scrcpy")
    }

    @Test("ADB is always passed, because a GUI-launched app has a minimal PATH")
    func passesAdb() {
        #expect(make(.default).environment["ADB"] == "/sdk/platform-tools/adb")
    }

    @Test("each option maps to the documented flag")
    func optionFlags() {
        let invocation = make(MirroringOptions(
            maxSize: 1280, maxFPS: 30, turnScreenOff: true, viewOnly: true, stayAwake: true
        ))
        #expect(invocation.arguments.contains("--max-size=1280"))
        #expect(invocation.arguments.contains("--max-fps=30"))
        #expect(invocation.arguments.contains("--turn-screen-off"))
        #expect(invocation.arguments.contains("--no-control"))
        #expect(invocation.arguments.contains("--stay-awake"))
    }

    @Test("audio modes map to documented scrcpy flags")
    func audioModeFlags() {
        #expect(make(MirroringOptions(audioMode: .phoneOnly)).arguments.contains("--no-audio"))
        #expect(!make(MirroringOptions(audioMode: .macOnly)).arguments.contains("--no-audio"))
        let bothArgs = make(MirroringOptions(audioMode: .both)).arguments
        #expect(bothArgs.contains("--audio-source=playback"))
        #expect(bothArgs.contains("--audio-dup"))
        #expect(make(MirroringOptions(audioMode: .disabled)).arguments.contains("--no-audio-playback"))
    }

    @Test("out-of-range numbers are dropped instead of forwarded")
    func dropsBadNumbers() {
        let invocation = make(MirroringOptions(maxSize: 10, maxFPS: 9_999))
        #expect(!invocation.arguments.contains { $0.hasPrefix("--max-size") })
        #expect(!invocation.arguments.contains { $0.hasPrefix("--max-fps") })
    }

    @Test("hostile input stays inside one argument and cannot add flags")
    func hostileInput() {
        let invocation = make(.default, serial: "X; rm -rf ~ --no-audio", title: "a --no-control b")
        #expect(invocation.arguments[0] == "--serial=X; rm -rf ~ --no-audio")
        #expect(invocation.arguments[1] == "--window-title=a --no-control b")
        #expect(invocation.arguments.filter { $0 == "--no-control" }.isEmpty)
        #expect(invocation.arguments.count == 3)
    }
}

@Suite("log ring buffer")
struct LineRingBufferTests {
    @Test("keeps only the most recent lines")
    func bounded() {
        var buffer = LineRingBuffer(capacity: 3)
        buffer.append((1...10).map { "line \($0)\n" }.joined())
        #expect(buffer.snapshot == ["line 8", "line 9", "line 10"])
    }

    @Test("reassembles a line split across chunks")
    func splitChunks() {
        var buffer = LineRingBuffer(capacity: 10)
        buffer.append("INFO: start")
        buffer.append("ed ok\nWARN: x\n")
        #expect(buffer.snapshot == ["INFO: started ok", "WARN: x"])
    }

    @Test("a final line with no newline is still visible after a crash")
    func trailingPartial() {
        var buffer = LineRingBuffer(capacity: 10)
        buffer.append("first\nERROR: died mid-wri")
        #expect(buffer.snapshot == ["first", "ERROR: died mid-wri"])
    }
}

/// Drives `MirroringSession` against tiny shell scripts, so process control is proven without a
/// phone or a window server.
@Suite("Mirroring session", .serialized)
struct MirroringSessionTests {
    private func script(_ body: String) throws -> String {
        let path = NSTemporaryDirectory() + "klyndro-fake-\(UUID().uuidString).sh"
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func invocation(_ path: String) -> ScrcpyCommand.Invocation {
        ScrcpyCommand.Invocation(executable: path, arguments: [], environment: [:])
    }

    private func waitFor(
        _ session: MirroringSession,
        timeout: TimeInterval = 6,
        _ predicate: (MirroringState) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(session.state) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate(session.state)
    }

    @Test("a missing executable fails with an actionable message, not a hang")
    func missingExecutable() {
        let session = MirroringSession()
        let error = session.start(invocation("/nonexistent/scrcpy"))
        #expect(error != nil)
        if case .failed(let reason) = session.state {
            #expect(reason.contains("not found"))
        } else {
            Issue.record("expected failed, got \(session.state)")
        }
    }

    @Test("a long-running process reaches running, then stops cleanly on request")
    func runThenStop() async throws {
        let path = try script("sleep 30")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let session = MirroringSession()
        #expect(session.start(invocation(path)) == nil)
        #expect(await waitFor(session) { $0 == .running })

        session.stop()
        #expect(await waitFor(session) { $0 == .idle })
    }

    @Test("a process that dies at once is reported as failed with its stderr")
    func quickFailure() async throws {
        let path = try script("echo 'ERROR: device unauthorized' >&2; exit 1")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let session = MirroringSession()
        #expect(session.start(invocation(path)) == nil)
        #expect(await waitFor(session) { if case .failed = $0 { return true } else { return false } })
        if case .failed(let reason) = session.state {
            #expect(reason.contains("device unauthorized"))
        }
    }

    @Test("a clean exit goes back to idle, not failed")
    func cleanExit() async throws {
        let path = try script("exit 0")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let session = MirroringSession()
        #expect(session.start(invocation(path)) == nil)
        #expect(await waitFor(session) { $0 == .idle })
    }

    @Test("starting twice does not spawn a second process")
    func noDoubleStart() async throws {
        let path = try script("sleep 30")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let session = MirroringSession()
        #expect(session.start(invocation(path)) == nil)
        #expect(session.start(invocation(path)) == "Mirroring is already running.")
        session.stop()
        #expect(await waitFor(session) { $0 == .idle })
    }

    @Test("a process that ignores SIGTERM is killed after the grace period")
    func escalatesToKill() async throws {
        let path = try script("trap '' TERM; while true; do sleep 1; done")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let session = MirroringSession()
        #expect(session.start(invocation(path)) == nil)
        #expect(await waitFor(session) { $0 == .running })

        session.stop()
        // Grace is 5 s; allow headroom for scheduling.
        #expect(await waitFor(session, timeout: 9) { $0 == .idle })
        #expect(session.recentLog.contains { $0.contains("killed") })
    }
}
