import Foundation
import KlyndroKit
import Observation

/// Screen mirroring state, kept apart from the connection code in `AppModel`.
///
/// The mirroring window itself belongs to scrcpy (ADR 0004). This only decides *whether* and
/// *against which device* to launch it, and reports what the child process is really doing.
@MainActor
@Observable
final class MirroringController {
    private(set) var devices: [AdbDevice] = []
    private(set) var state: MirroringState = .idle
    private(set) var lastMessage: String?
    private(set) var isRefreshing = false
    var selectedSerial: String?
    var options = MirroringOptions.default

    private let session = MirroringSession()
    private var toolchain: ToolchainReport?

    init() {
        let observer: @Sendable (MirroringState) -> Void = { [weak self] newState in
            Task { @MainActor in self?.apply(newState) }
        }
        session.setObserver(observer)
    }

    var isActive: Bool { state.isActive }

    /// Why Start is unavailable, in words a user can act on. `nil` means it can start.
    var blockingReason: String? {
        guard let toolchain else { return "Checking tools…" }
        if toolchain.tools.first(where: { $0.name == "adb" })?.path == nil {
            return "adb is not installed. Install Android platform-tools (brew install android-platform-tools)."
        }
        if toolchain.tools.first(where: { $0.name == "scrcpy" })?.path == nil {
            return "scrcpy is not installed. Run: brew install scrcpy"
        }
        guard let device = selectedDevice else {
            return devices.isEmpty
                ? "No Android device found. Connect by USB and enable USB debugging."
                : "Choose a device."
        }
        return device.actionableProblem
    }

    var selectedDevice: AdbDevice? {
        devices.first { $0.serial == selectedSerial } ?? devices.first(where: \.isUsable)
    }

    func updateToolchain(_ report: ToolchainReport?) {
        toolchain = report
    }

    /// Lists attached devices. Runs adb off the main actor; output is parsed by `AdbDevicesParser`.
    func refreshDevices() async {
        guard let adb = toolchain?.tools.first(where: { $0.name == "adb" })?.path else {
            devices = []
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let output = await Task.detached(priority: .utility) { Self.run(adb, ["devices", "-l"]) }.value
        devices = AdbDevicesParser.parse(output)

        if let selected = selectedSerial, !devices.contains(where: { $0.serial == selected }) {
            selectedSerial = nil
        }
        if selectedSerial == nil { selectedSerial = devices.first(where: \.isUsable)?.serial }
    }

    func start() {
        if let reason = blockingReason {
            lastMessage = reason
            NSLog("[Klyndro] mirroring blocked: %{public}@", reason)
            return
        }
        guard let device = selectedDevice,
              let adb = toolchain?.tools.first(where: { $0.name == "adb" })?.path,
              let scrcpy = toolchain?.tools.first(where: { $0.name == "scrcpy" })?.path
        else { return }

        lastMessage = nil
        let title = "Klyndro — \(device.model ?? device.serial)"
        let invocation = ScrcpyCommand.make(
            scrcpyPath: scrcpy,
            adbPath: adb,
            serial: device.serial,
            windowTitle: title,
            options: options
        )
        NSLog("[Klyndro] mirroring start: %{public}@ %{public}@", invocation.executable, invocation.arguments.joined(separator: " "))
        if let error = session.start(invocation) { lastMessage = error }
    }

    func stop() {
        session.stop()
    }

    /// Last lines of scrcpy's own output, for the diagnostics panel.
    var recentLog: [String] { session.recentLog }

    private func apply(_ newState: MirroringState) {
        NSLog("[Klyndro] mirroring state: %{public}@", String(describing: newState))
        state = newState
        if case .failed(let reason) = newState { lastMessage = reason }
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        // Read before waiting: a full pipe would otherwise block the child forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
