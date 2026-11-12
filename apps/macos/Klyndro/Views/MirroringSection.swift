import KlyndroKit
import SwiftUI

/// Mirroring controls for the main window. The video window itself is scrcpy's.
struct MirroringSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showingPairing = false
    @State private var pairingAddress = ""
    @State private var pairingCode = ""

    var body: some View {
        @Bindable var mirroring = model.mirroring

        GroupBox("Screen mirroring") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if model.isStandardMirroring {
                        Button(role: .destructive) {
                            Task { await model.stopStandardMirroring(reason: "user_stopped") }
                        } label: {
                            Label("Stop Screen Mirroring", systemImage: "stop.circle")
                        }
                    } else {
                        Button {
                            openWindow(id: "standard-mirror")
                            Task { await model.startStandardMirroring() }
                        } label: {
                            Label("Start Screen Mirroring", systemImage: "play.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.isConnected)
                        .help("Standard Mode: mirror over local Wi-Fi without ADB or scrcpy")
                    }

                    Text(model.isStandardMirroring ? (model.standardMirrorReceiver?.statusText ?? model.standardMirrorStatus) : "Standard Mode (No ADB)")
                        .font(.caption)
                        .foregroundStyle(model.isStandardMirroring ? .green : .secondary)
                }

                Text(
                    "Default mode works over Wi-Fi without ADB or Developer Options. "
                    + "Approve the screen-sharing prompt on your phone; enable Klyndro in Android Accessibility settings for mouse/touch control."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Divider()

                DisclosureGroup("Advanced Mode (ADB / scrcpy)") {
                    VStack(alignment: .leading, spacing: 10) {
                        deviceRow(mirroring)

                        if let reason = mirroring.blockingReason, !mirroring.isActive {
                            Label(reason, systemImage: "info.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        wirelessRow(mirroring)

                        optionsRow(mirroring)

                        HStack {
                            if mirroring.isActive {
                                Button(role: .destructive) {
                                    mirroring.stop()
                                } label: {
                                    Label("Stop ADB mirroring", systemImage: "stop.circle")
                                }
                                .disabled(mirroring.state == .stopping)
                            } else {
                                Button {
                                    Task { await mirroring.startOrGuide() }
                                } label: {
                                    Label("Start ADB mirroring", systemImage: "play.circle")
                                }
                                .disabled(mirroring.toolProblem != nil || mirroring.isConnectingWirelessly)
                            }

                            Text(stateText(mirroring.state))
                                .font(.caption)
                                .foregroundStyle(stateColor(mirroring.state))
                        }

                        if case .failed = mirroring.state, !mirroring.recentLog.isEmpty {
                            DisclosureGroup("scrcpy output") {
                                Text(mirroring.recentLog.suffix(12).joined(separator: "\n"))
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.caption)
                        }

                        Text(
                            "Uses your own scrcpy and adb for full keyboard shortcuts, screen-off mode, and structured ADB controls."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        DisclosureGroup("Advanced ADB controls") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    ForEach(AdbNavKey.allCases, id: \.self) { key in
                                        Button(key.displayName) {
                                            Task { await mirroring.sendNavKey(key) }
                                        }
                                        .disabled(mirroring.toolProblem != nil || mirroring.isRunningAdbAction)
                                    }
                                    Spacer()
                                    Button {
                                        Task { await mirroring.takeScreenshot() }
                                    } label: {
                                        Label("Screenshot", systemImage: "camera")
                                    }
                                    .disabled(mirroring.toolProblem != nil || mirroring.isRunningAdbAction)
                                }

                                HStack(spacing: 8) {
                                    Picker("App", selection: Binding(
                                        get: { mirroring.selectedPackage },
                                        set: { mirroring.selectedPackage = $0 }
                                    )) {
                                        if mirroring.installedPackages.isEmpty {
                                            Text("Tap Refresh to load apps").tag("")
                                        }
                                        ForEach(mirroring.installedPackages, id: \.value) { pkg in
                                            Text(pkg.value).tag(pkg.value)
                                        }
                                    }
                                    .disabled(mirroring.installedPackages.isEmpty || mirroring.isRunningAdbAction)

                                    Button {
                                        Task { await mirroring.refreshInstalledPackages() }
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .help("List user apps via adb")
                                    .disabled(mirroring.toolProblem != nil || mirroring.isRunningAdbAction)

                                    Button("Open App") {
                                        Task { await mirroring.launchSelectedPackage() }
                                    }
                                    .disabled(mirroring.selectedPackage.isEmpty || mirroring.isRunningAdbAction)
                                }

                                if let msg = mirroring.adbActionMessage {
                                    Text(msg)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.top, 6)
                        }
                        .font(.callout)
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func deviceRow(_ mirroring: MirroringController) -> some View {
        HStack(spacing: 8) {
            Picker("Device", selection: Binding(
                get: { mirroring.selectedSerial ?? "" },
                set: { mirroring.selectedSerial = $0.isEmpty ? nil : $0 }
            )) {
                if mirroring.devices.isEmpty { Text("No device").tag("") }
                ForEach(mirroring.devices) { device in
                    Text(label(for: device)).tag(device.serial)
                }
            }
            .disabled(mirroring.isActive || mirroring.devices.isEmpty)

            Button {
                Task { await mirroring.refreshDevices() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rescan attached devices")
            .disabled(mirroring.isRefreshing || mirroring.isActive)
        }
    }

    @ViewBuilder
    private func wirelessRow(_ mirroring: MirroringController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await mirroring.connectWirelessly() }
                } label: {
                    Label("Connect over Wi-Fi", systemImage: "wifi")
                }
                .disabled(mirroring.isConnectingWirelessly || mirroring.isActive)

                Button("First time? Pair…") { showingPairing.toggle() }
                    .buttonStyle(.link)

                if mirroring.isConnectingWirelessly { ProgressView().controlSize(.small) }
            }

            if let message = mirroring.wirelessMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if showingPairing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On the phone: Developer options > Wireless debugging > Pair device with pairing code. Keep that dialog open and enter what it shows. You only do this once.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("IP:port (192.168.1.20:37099)", text: $pairingAddress)
                            .textFieldStyle(.roundedBorder)
                        TextField("Code", text: $pairingCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Button("Pair") {
                            let address = pairingAddress
                            let code = pairingCode
                            Task {
                                await mirroring.pairWirelessly(address: address, code: code)
                                pairingCode = ""
                            }
                        }
                        .disabled(mirroring.isConnectingWirelessly)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func optionsRow(_ mirroring: MirroringController) -> some View {
        @Bindable var mirroring = mirroring
        HStack(spacing: 16) {
            Toggle("View only", isOn: $mirroring.options.viewOnly)
            Toggle("Turn phone screen off", isOn: $mirroring.options.turnScreenOff)
            Picker("Max size", selection: $mirroring.options.maxSize) {
                Text("Device").tag(Int?.none)
                Text("1920").tag(Int?.some(1920))
                Text("1280").tag(Int?.some(1280))
                Text("1024").tag(Int?.some(1024))
            }
            .frame(maxWidth: 170)
            Picker("FPS", selection: $mirroring.options.maxFPS) {
                Text("Default").tag(Int?.none)
                Text("60").tag(Int?.some(60))
                Text("30").tag(Int?.some(30))
            }
            .frame(maxWidth: 150)
        }
        .disabled(mirroring.isActive)
        .font(.callout)
    }

    private func label(for device: AdbDevice) -> String {
        let name = device.model ?? device.serial
        let kind = device.transport == .wireless ? "Wi-Fi" : "USB"
        let status = device.isUsable ? "" : " — \(statusWord(device.state))"
        return "\(name) (\(kind))\(status)"
    }

    private func statusWord(_ state: AdbDeviceState) -> String {
        switch state {
        case .device: return "ready"
        case .unauthorized: return "unauthorized"
        case .offline: return "offline"
        case .other(let raw): return raw
        }
    }

    private func stateText(_ state: MirroringState) -> String {
        switch state {
        case .idle: return "Not mirroring"
        case .starting: return "Starting…"
        case .running: return "Mirroring"
        case .stopping: return "Stopping…"
        case .failed: return "Stopped with an error"
        }
    }

    private func stateColor(_ state: MirroringState) -> Color {
        switch state {
        case .running: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}
