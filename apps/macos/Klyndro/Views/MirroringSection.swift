import KlyndroKit
import SwiftUI

/// Mirroring controls using native macOS grouped Form layout.
struct MirroringSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PreferenceKeys.mirroringMode) private var mirroringModeRaw = MirroringMode.standard.rawValue
    @AppStorage(PreferenceKeys.standardAudioEnabled) private var standardAudioEnabled = false

    private var mode: MirroringMode {
        MirroringMode(rawValue: mirroringModeRaw) ?? .standard
    }

    var body: some View {
        @Bindable var mirroring = model.mirroring

        Form {
            Section("Mirroring Mode") {
                Picker("Mode", selection: $mirroringModeRaw) {
                    ForEach(MirroringMode.allCases) { item in
                        Text(item.label).tag(item.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: mirroringModeRaw) { _, newValue in
                    if MirroringMode(rawValue: newValue) == .advanced {
                        Task {
                            await model.mirroring.guideAdvancedSetupIfNeeded(isConnected: model.isConnected)
                        }
                    }
                }
            }

            if mode == .standard {
                standardCard
            } else {
                Section {
                LabeledContent("Device") {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(
                            get: { mirroring.selectedSerial ?? "" },
                            set: { mirroring.selectedSerial = $0.isEmpty ? nil : $0 }
                        )) {
                            if mirroring.devices.isEmpty { Text("No device").tag("") }
                            ForEach(mirroring.devices) { device in
                                Text(label(for: device)).tag(device.serial)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
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

                LabeledContent("Wireless ADB") {
                    HStack(spacing: 10) {
                        if mirroring.isConnectingWirelessly {
                            ProgressView().controlSize(.small)
                        }
                        Button {
                            Task { await mirroring.connectWirelessly(showPopupOnFailure: true) }
                        } label: {
                            Label("Connect over Wi-Fi", systemImage: "wifi")
                        }
                        .disabled(mirroring.isConnectingWirelessly || mirroring.isActive)
                    }
                }

                if let message = mirroring.wirelessMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Toggle("View only (disable mouse & keyboard)", isOn: $mirroring.options.viewOnly)
                    .disabled(mirroring.isActive)

                Toggle("Turn phone screen off while mirroring", isOn: $mirroring.options.turnScreenOff)
                    .disabled(mirroring.isActive)

                Picker("Max resolution", selection: $mirroring.options.maxSize) {
                    Text("Device native").tag(Int?.none)
                    Text("1080p").tag(Int?.some(1080))
                    Text("1440p").tag(Int?.some(1440))
                }
                .disabled(mirroring.isActive)

                Picker("Frame rate limit", selection: $mirroring.options.maxFPS) {
                    Text("Default").tag(Int?.none)
                    Text("30 fps").tag(Int?.some(30))
                    Text("60 fps").tag(Int?.some(60))
                }
                .disabled(mirroring.isActive)

                Picker("Audio", selection: $mirroring.options.audioMode) {
                    ForEach(MirrorAudioMode.allCases) { audio in
                        Text(audio.label).tag(audio)
                    }
                }
                .disabled(mirroring.isActive)

                if let reason = mirroring.blockingReason, !mirroring.isActive {
                    Label(reason, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text(stateText(mirroring.state))
                        .font(.caption)
                        .foregroundStyle(stateColor(mirroring.state))
                    Spacer()
                    if mirroring.isActive {
                        Button(role: .destructive) {
                            mirroring.stop()
                        } label: {
                            Label("Stop ADB Mirroring", systemImage: "stop.circle")
                        }
                        .disabled(mirroring.state == .stopping)
                    } else {
                        Button {
                            Task { await mirroring.startOrGuide() }
                        } label: {
                            Label("Start ADB Mirroring", systemImage: "play.circle")
                        }
                        .disabled(!model.isConnected || mirroring.toolProblem != nil || mirroring.isConnectingWirelessly)
                    }
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
            } header: {
                Text("Advanced Mode (ADB / scrcpy)")
            }

            Section {
                LabeledContent("Navigation") {
                    HStack(spacing: 6) {
                        ForEach(AdbNavKey.allCases, id: \.self) { key in
                            Button(key.displayName) {
                                Task { await mirroring.sendNavKey(key) }
                            }
                            .disabled(!model.isConnected || mirroring.toolProblem != nil || mirroring.isRunningAdbAction)
                        }
                    }
                }

                LabeledContent("Screen capture") {
                    Button {
                        Task { await mirroring.takeScreenshot() }
                    } label: {
                        Label("Save Screenshot to Downloads", systemImage: "camera")
                    }
                    .disabled(!model.isConnected || mirroring.toolProblem != nil || mirroring.isRunningAdbAction)
                }

                LabeledContent("Launch app") {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(
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
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .disabled(mirroring.installedPackages.isEmpty || mirroring.isRunningAdbAction)

                        Button {
                            Task { await mirroring.refreshInstalledPackages() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Load user apps via adb")
                        .disabled(!model.isConnected || mirroring.toolProblem != nil || mirroring.isRunningAdbAction)

                        Button("Open App") {
                            Task { await mirroring.launchSelectedPackage() }
                        }
                        .disabled(!model.isConnected || mirroring.selectedPackage.isEmpty || mirroring.isRunningAdbAction)
                    }
                }

                if let msg = mirroring.adbActionMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("ADB Quick Actions (Paired Phone Only)")
            }
            }
        }
        .formStyle(.grouped)
    }

    private var standardCard: some View {
        Section("Standard Mode (No ADB)") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mirror over local Wi-Fi without ADB")
                        .font(.body.weight(.medium))
                    Text("Enable Klyndro Remote Control in Android Accessibility settings for mouse, touch, and keyboard input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isStandardMirroring {
                    Button(role: .destructive) {
                        Task { await model.stopStandardMirroring(reason: "user_stopped") }
                    } label: {
                        Label("Stop Mirroring", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        openWindow(id: "standard-mirror")
                        Task { await model.startStandardMirroring() }
                    } label: {
                        Label("Start Mirroring", systemImage: "play.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isConnected)
                }
            }

            Toggle("Forward phone audio to Mac (Mac + Phone)", isOn: $standardAudioEnabled)
                .disabled(model.isStandardMirroring)
            Text("Requires Mirror audio permission on Android; Android does not allow muting the phone speaker without ADB, and DRM apps may block audio capture.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func label(for device: AdbDevice) -> String {
        let name = device.model ?? device.serial
        let transport = device.transport == .wireless ? "Wi-Fi" : "USB"
        if device.isUsable { return "\(name) (\(transport))" }
        return "\(name) — \(device.state)"
    }

    private func stateText(_ state: MirroringState) -> String {
        switch state {
        case .idle: return "Not mirroring"
        case .starting: return "Starting…"
        case .running: return "Mirroring"
        case .stopping: return "Stopping…"
        case .failed(let reason): return reason
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
