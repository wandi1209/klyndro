import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @AppStorage(PreferenceKeys.clipboardSyncEnabled) private var clipboardSync = true
    @AppStorage(PreferenceKeys.notificationsEnabled) private var notifications = false
    @AppStorage(PreferenceKeys.autoReconnect) private var autoReconnect = true

    var body: some View {
        Text("Klyndro — \(model.connectionSummary)")
        if model.isConnected {
            Text("Clipboard: \(model.clipboardSentCount) sent · \(model.clipboardAppliedCount) received")
        }

        Divider()

        Toggle("Clipboard Sync", isOn: $clipboardSync)
        Toggle("Notifications", isOn: $notifications)
        Toggle("Reconnect Automatically", isOn: $autoReconnect)

        Divider()

        Button("Open Klyndro") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        if model.isStandardMirroring {
            Button("Stop Screen Mirroring") {
                Task { await model.stopStandardMirroring(reason: "user_stopped") }
            }
        } else {
            Button("Start Screen Mirroring") {
                openWindow(id: "standard-mirror")
                NSApp.activate(ignoringOtherApps: true)
                Task { await model.startStandardMirroring() }
            }
            .disabled(!model.isConnected)
            .help("Standard Mode (no ADB or scrcpy required)")
        }

        if model.mirroring.isActive {
            Button("Stop ADB Mirroring (scrcpy)") { model.mirroring.stop() }
        } else {
            Button("Advanced Mirroring (ADB / scrcpy)") { Task { await model.mirroring.startOrGuide() } }
                .disabled(model.mirroring.toolProblem != nil)
                .help(model.mirroring.toolProblem ?? "Mirror the phone with scrcpy + adb")
        }

        Divider()

        SettingsLink { Text("Settings…") }

        Button("Quit Klyndro") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
