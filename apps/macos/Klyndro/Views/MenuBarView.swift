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
        Text("Connectivity arrives in milestone M1")

        Divider()

        Toggle("Clipboard Sync", isOn: $clipboardSync)
        Toggle("Notifications", isOn: $notifications)
        Toggle("Reconnect Automatically", isOn: $autoReconnect)

        Divider()

        Button("Open Klyndro") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        if model.mirroring.isActive {
            Button("Stop Screen Mirroring") { model.mirroring.stop() }
        } else {
            Button("Start Screen Mirroring") { model.mirroring.start() }
                .disabled(model.mirroring.blockingReason != nil)
                .help(model.mirroring.blockingReason ?? "Mirror the phone with scrcpy")
        }

        Divider()

        SettingsLink { Text("Settings…") }

        Button("Quit Klyndro") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
