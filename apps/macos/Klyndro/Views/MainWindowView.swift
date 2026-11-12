import AppKit
import KlyndroKit
import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @State private var showingDiagnostics = false

    @AppStorage(PreferenceKeys.clipboardSyncEnabled) private var clipboardSync = true
    @AppStorage(PreferenceKeys.notificationsEnabled) private var notifications = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = model.identityError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    statusSection
                    devicesSection
                    discoveredSection
                    MirroringSection()
                    toolchainSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 660, minHeight: 480)
        .task { await model.probeToolchain() }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsView()
                .environment(model)
        }
        .sheet(isPresented: Binding(
            get: { model.pairingPrompt != nil || model.pairingFailure != nil },
            set: { _ in }
        )) {
            PairingSheet()
                .environment(model)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Klyndro")
                    .font(.title2.weight(.semibold))
                Text("Your devices, seamlessly connected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showingDiagnostics = true
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusSection: some View {
        GroupBox("Status") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Connection") {
                    Text(model.connectionSummary)
                        .foregroundStyle(model.isConnected ? .primary : .secondary)
                }
                LabeledContent("This device") {
                    Text(model.identityFingerprintShort)
                        .monospaced()
                        .textSelection(.enabled)
                }
                LabeledContent("Listening") {
                    if let error = model.listenerError {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text(model.isListening ? "Yes, on port \(AppModel.servicePort)" : "No")
                            .foregroundStyle(model.isListening ? .primary : .secondary)
                    }
                }
                LabeledContent("Clipboard sync", value: clipboardSync ? "On" : "Off")
                LabeledContent("Notifications", value: notifications ? "On" : "Off")

                if model.isConnected {
                    LabeledContent(
                        "Clipboard",
                        value: "\(model.clipboardSentCount) sent · \(model.clipboardAppliedCount) received"
                    )
                }

                Text(
                    "Clipboard sync from the phone only runs while Klyndro is on screen on Android; "
                    + "that is an Android restriction."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var devicesSection: some View {
        GroupBox("Paired devices") {
            VStack(alignment: .leading, spacing: 10) {
                if model.pairedPeers.isEmpty {
                    Text("No paired devices yet.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(model.pairedPeers) { peer in
                        HStack(spacing: 10) {
                            Image(systemName: peer.platform == "android" ? "iphone.gen3" : "laptopcomputer")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(peer.name).font(.body.weight(.medium))
                                Text("\(peer.platform) · \(peer.fingerprintValue?.shortHex ?? "—")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let device = model.devices.first(where: { $0.id == peer.deviceID }) {
                                Text(device.connectionState.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Forget") { model.unpair(peer) }
                                .buttonStyle(.borderless)
                        }
                    }
                }

                Divider()

                HStack {
                    Button {
                        Task { await model.beginPairing() }
                    } label: {
                        Label("Pair a device…", systemImage: "plus.circle")
                    }
                    .disabled(model.identity == nil || model.isPairingWindowOpen)

                    if model.isPairingWindowOpen {
                        Text("Pairing window open for 60 seconds")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var discoveredSection: some View {
        GroupBox("Nearby devices") {
            VStack(alignment: .leading, spacing: 8) {
                if model.discoveredPeers.isEmpty {
                    Text("Searching the local network…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.discoveredPeers) { peer in
                        HStack(spacing: 10) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(peer.name).font(.body.weight(.medium))
                                Text(peer.isPaired ? "Paired" : "Not paired")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }

                Text("Devices are discovered over Bonjour. Being visible says nothing about trust; a session still requires a pinned key.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var toolchainSection: some View {
        GroupBox("System tools") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.toolchain?.tools ?? []) { tool in
                    HStack(spacing: 8) {
                        Image(systemName: tool.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(tool.isAvailable ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.name).font(.body.weight(.medium))
                            Text(tool.version ?? tool.purpose)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                }

                if let toolchain = model.toolchain, !toolchain.missingRequired.isEmpty {
                    Text("Mirroring will not work until adb is installed. See Diagnostics.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if model.toolchain == nil {
                    Text(model.isProbingToolchain ? "Checking…" : "Not checked yet")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
