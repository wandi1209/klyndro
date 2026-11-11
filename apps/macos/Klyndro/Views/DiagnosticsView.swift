import AppKit
import KlyndroKit
import SwiftUI

/// Shows what Klyndro found on this machine. Introduced in M0 because "mirroring does
/// nothing" is almost always a missing or invisible `adb`, and a GUI app does not inherit
/// the `PATH` a terminal has.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Diagnostics")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
            }

            GroupBox("Build") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Version", value: BuildInfo.appVersion)
                    LabeledContent("Build", value: BuildInfo.buildNumber)
                    LabeledContent("macOS", value: BuildInfo.operatingSystem)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("External tools") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.toolchain?.tools ?? []) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: tool.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(tool.isAvailable ? Color.green : Color.red)
                                Text(tool.name).font(.body.weight(.medium))
                                if tool.required {
                                    Text("required")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            Text(tool.path ?? "Not found — \(tool.purpose)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let version = tool.version {
                                Text(version)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let lastProbedAt = model.lastProbedAt {
                Text("Checked \(lastProbedAt.formatted(date: .omitted, time: .standard))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    Task { await model.probeToolchain() }
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
                .disabled(model.isProbingToolchain)

                Spacer()

                Button("Copy report") { copyReport() }
                    .disabled(model.toolchain == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            if model.toolchain == nil {
                await model.probeToolchain()
            }
        }
    }

    /// Copies the report the user just asked for. It contains paths and versions only —
    /// never clipboard content, notification text, or credentials.
    private func copyReport() {
        var lines = [BuildInfo.summary, ""]
        for tool in model.toolchain?.tools ?? [] {
            lines.append("\(tool.name): \(tool.path ?? "not found") — \(tool.version ?? "unknown version")")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
