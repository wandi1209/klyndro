import AppKit
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
    /// Result of the last Wi-Fi attempt, shown next to the controls. Never contains the pairing code.
    private(set) var wirelessMessage: String?
    private(set) var isConnectingWirelessly = false
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

    /// Why mirroring cannot work at all on this Mac (missing tools). Device problems are not
    /// listed here: those are handled by `startOrGuide`, which explains them in a popup.
    var toolProblem: String? {
        guard let toolchain else { return "Checking tools…" }
        if toolchain.tools.first(where: { $0.name == "adb" })?.path == nil {
            return "adb is not installed. Install Android platform-tools (brew install android-platform-tools)."
        }
        if toolchain.tools.first(where: { $0.name == "scrcpy" })?.path == nil {
            return "scrcpy is not installed. Run: brew install scrcpy"
        }
        return nil
    }

    /// Why Start is unavailable, in words a user can act on. `nil` means it can start.
    var blockingReason: String? {
        if let toolProblem { return toolProblem }
        guard let device = selectedDevice else {
            return devices.isEmpty
                ? "No Android device found. Turn on Wireless debugging or USB debugging on the phone."
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

    /// Looks for phones with Wireless debugging on and runs `adb connect` for each. Works only for
    /// phones already paired with this Mac's adb, so it cannot reach a device that never approved it.
    @discardableResult
    func connectWirelessly() async -> Bool {
        guard let adb = adbPath else {
            wirelessMessage = "adb is not installed."
            return false
        }
        guard !isConnectingWirelessly else { return false }
        isConnectingWirelessly = true
        defer { isConnectingWirelessly = false }
        wirelessMessage = "Looking for phones with Wireless debugging…"

        let endpoints = await WirelessAdbDiscovery.scanConnectEndpoints()
        guard !endpoints.isEmpty else {
            wirelessMessage = "No phone is offering Wireless debugging on this network. "
                + "Turn it on in Developer options, and make sure both devices share the Wi-Fi."
            return false
        }

        var connected = false
        var lastFailure = ""
        var restartedServer = false
        for endpoint in endpoints {
            var attempt = 0
            while attempt < 2 {
                attempt += 1
                let output = await Task.detached(priority: .utility) {
                    AdbProcess.run(adb, ["connect", endpoint.address])
                }.value
                switch AdbWirelessParser.parseConnect(output.text) {
                case .success:
                    connected = true
                    attempt = 2
                case .failure(let reason):
                    lastFailure = output.timedOut ? "adb connect timed out" : reason
                    // An adb server left running by another program (a terminal, an IDE) keeps its
                    // own network permissions, and macOS can refuse its LAN connections with
                    // "No route to host" while Klyndro itself is allowed. Restarting it once lets
                    // Klyndro start the server it is entitled to use. Devices stay authorised.
                    if attempt == 1, !restartedServer, lastFailure.contains("No route to host") {
                        restartedServer = true
                        _ = await Task.detached(priority: .utility) {
                            AdbProcess.run(adb, ["kill-server"], timeout: 5)
                        }.value
                    } else {
                        attempt = 2
                    }
                }
            }
        }

        await refreshDevices()
        wirelessMessage = connected
            ? nil
            : "Found a phone but could not connect: \(lastFailure). If this is the first time, pair it below."
        return connected
    }

    /// One-time pairing with the code shown in "Pair device with pairing code". The address is the
    /// pairing address on that dialog, not the one on the main Wireless debugging screen.
    func pairWirelessly(address: String, code: String) async {
        guard let adb = adbPath else {
            wirelessMessage = "adb is not installed."
            return
        }
        guard let endpoint = AdbEndpoint(address: address) else {
            wirelessMessage = "Enter the pairing address as IP:port, for example 192.168.1.20:37099."
            return
        }
        guard let pairingCode = AdbPairingCode(code) else {
            wirelessMessage = "The pairing code is six digits."
            return
        }
        guard !isConnectingWirelessly else { return }
        isConnectingWirelessly = true
        defer { isConnectingWirelessly = false }
        wirelessMessage = "Pairing…"

        // adb takes the code as an argument, so it is visible to other processes of this user for
        // the few seconds pairing takes. The code is single-use and expires with the dialog.
        let output = await Task.detached(priority: .utility) {
            AdbProcess.run(adb, ["pair", endpoint.address, pairingCode.value], timeout: 15)
        }.value

        switch AdbWirelessParser.parsePair(output.text) {
        case .success:
            wirelessMessage = "Paired. Connecting…"
            if !(await connectWirelessly()) {
                wirelessMessage = (wirelessMessage ?? "") + " Pairing worked; open Wireless debugging on the phone and try Connect again."
            }
        case .failure(let reason):
            wirelessMessage = output.timedOut
                ? "Pairing timed out. Keep the pairing dialog open on the phone and try again."
                : "Pairing failed: \(reason). The code is single-use; reopen the dialog for a new one."
        }
    }

    /// Reconnects over Wi-Fi without user input. Silent when nothing is attached and no phone is
    /// advertising Wireless debugging, so it never surfaces an error for a phone that is simply away.
    func autoConnectIfNeeded() async {
        guard !isActive, !isConnectingWirelessly, adbPath != nil else { return }
        await refreshDevices()
        guard devices.contains(where: \.isUsable) == false else { return }
        let connected = await connectWirelessly()
        if !connected { wirelessMessage = nil }
    }

    private var adbPath: String? {
        toolchain?.tools.first(where: { $0.name == "adb" })?.path
    }

    /// Start button behaviour: look for a phone (USB, then Wi-Fi), start mirroring when one is
    /// usable, and otherwise explain what to switch on instead of leaving a disabled button.
    func startOrGuide() async {
        guard !isActive else { return }
        if let problem = toolProblem {
            lastMessage = problem
            present(title: "Mirroring is not available", message: problem)
            return
        }

        await refreshDevices()
        if !devices.contains(where: \.isUsable) {
            await connectWirelessly()
        }
        guard devices.contains(where: \.isUsable) else {
            let guidance = MirroringGuidance.make(devices: devices)
            lastMessage = guidance.message
            present(title: guidance.title, message: guidance.message)
            return
        }
        start()
    }

    private func present(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
