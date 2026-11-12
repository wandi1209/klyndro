import AppKit
import KlyndroKit
import SwiftUI
import UniformTypeIdentifiers

private enum MainTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case mirroring = "Mirroring"
    case system = "System"

    var id: String { rawValue }
}

struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selectedTab: MainTab = .overview
    @State private var showingDiagnostics = false

    @AppStorage(PreferenceKeys.clipboardSyncEnabled) private var clipboardSync = true
    @AppStorage(PreferenceKeys.notificationsEnabled) private var notifications = false
    @AppStorage(PreferenceKeys.mirroringMode) private var mirroringModeRaw = MirroringMode.standard.rawValue

    private var mirroringMode: MirroringMode {
        MirroringMode(rawValue: mirroringModeRaw) ?? .standard
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let error = model.identityError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }

            switch selectedTab {
            case .overview:
                overviewForm
            case .mirroring:
                MirroringSection()
            case .system:
                systemForm
            }
        }
        .frame(minWidth: 640, minHeight: 500)
        .task { await model.probeToolchain() }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsView()
                .environment(model)
        }
        .sheet(isPresented: Binding(
            get: { model.isPairingWindowOpen || model.pairingPrompt != nil || model.pairingFailure != nil },
            set: { _ in }
        )) {
            PairingSheet()
                .environment(model)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: appIconImage)
                .resizable()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Klyndro")
                        .font(.title3.weight(.semibold))
                    statusPill
                }
                Text("Your devices, seamlessly connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $selectedTab) {
                ForEach(MainTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(model.isConnected ? "Connected" : "Idle")
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill((model.isConnected ? Color.green : Color.orange).opacity(0.14))
        )
    }

    private var overviewForm: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.connectionSummary)
                            .font(.headline)
                        Text("Identity \(model.identityFingerprintShort)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        Task { await model.beginPairing() }
                    } label: {
                        Label("Pair Device", systemImage: "qrcode")
                    }
                    .disabled(model.identity == nil || model.isPairingWindowOpen)

                    Button {
                        if mirroringMode == .standard {
                            openWindow(id: "standard-mirror")
                            Task { await model.startStandardMirroring() }
                        } else {
                            Task { await model.mirroring.startOrGuide() }
                        }
                    } label: {
                        Label("Mirror Screen", systemImage: "iphone.gen3")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isConnected)
                }
            }

            Section("Sync & File Transfer") {
                LabeledContent("Clipboard sync", value: clipboardSync ? "On" : "Off")
                LabeledContent("Notifications", value: notifications ? "On" : "Off")
                if model.isConnected {
                    LabeledContent(
                        "Clipboard activity",
                        value: "\(model.clipboardSentCount) sent · \(model.clipboardAppliedCount) received"
                    )
                }
                LabeledContent("File transfer") {
                    HStack(spacing: 10) {
                        if let progress = model.fileSendProgress {
                            ProgressView(value: progress).frame(width: 100)
                        }
                        if let message = model.fileSendMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            chooseFileToSend()
                        } label: {
                            Label("Send file…", systemImage: "arrow.up.doc")
                        }
                        .disabled(!model.canSendFile)
                    }
                }
            }

            Section("Paired Devices") {
                if model.pairedPeers.isEmpty {
                    Text("No paired devices yet. Click Pair Device to show a QR code.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.pairedPeers) { peer in
                        HStack(spacing: 10) {
                            Image(systemName: peer.platform == "android" ? "iphone.gen3" : "laptopcomputer")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(peer.name).font(.body.weight(.medium))
                                Text(peer.fingerprintValue?.shortHex ?? "—")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let device = model.devices.first(where: { $0.id == peer.deviceID }) {
                                Text(device.connectionState.displayName)
                                    .font(.caption)
                                    .foregroundStyle(device.isConnected ? .green : .secondary)
                            }
                            Button("Forget") { model.unpair(peer) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }

            if !model.discoveredPeers.isEmpty {
                Section("Nearby (Bonjour)") {
                    ForEach(model.discoveredPeers) { peer in
                        LabeledContent(peer.name, value: peer.isPaired ? "Paired" : "Not paired")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var systemForm: some View {
        Form {
            Section("Listener & Identity") {
                LabeledContent("Listening") {
                    if let error = model.listenerError {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text(model.isListening ? "Yes, on port \(String(AppModel.servicePort))" : "No")
                            .foregroundStyle(model.isListening ? .primary : .secondary)
                    }
                }
                LabeledContent("Device fingerprint") {
                    Text(model.identityFingerprintShort)
                        .monospaced()
                        .textSelection(.enabled)
                }
            }

            Section("Optional Tools (for Advanced Mode)") {
                ForEach(model.toolchain?.tools ?? []) { tool in
                    LabeledContent {
                        Text(tool.version ?? tool.purpose)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } label: {
                        Label {
                            Text(tool.name)
                        } icon: {
                            Image(systemName: tool.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(tool.isAvailable ? Color.green : Color.orange)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        Task { await model.probeToolchain() }
                    } label: {
                        Label("Re-check tools", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isProbingToolchain)

                    Button {
                        showingDiagnostics = true
                    } label: {
                        Label("Open Diagnostics", systemImage: "stethoscope")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFileToSend() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Send"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.sendFile(at: url) }
    }

    private var appIconImage: NSImage {
        if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: icnsURL) {
            return image
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }
}
