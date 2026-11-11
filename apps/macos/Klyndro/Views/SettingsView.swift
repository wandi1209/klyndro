import SwiftUI

struct SettingsView: View {
    @AppStorage(PreferenceKeys.clipboardSyncEnabled) private var clipboardSync = true
    @AppStorage(PreferenceKeys.notificationsEnabled) private var notifications = false
    @AppStorage(PreferenceKeys.autoReconnect) private var autoReconnect = true
    @AppStorage(PreferenceKeys.allowSensitiveClipboard) private var allowSensitive = false

    var body: some View {
        Form {
            Section("Features") {
                Toggle("Sync clipboard between devices", isOn: $clipboardSync)
                Toggle("Forward Android notifications", isOn: $notifications)
                Toggle("Reconnect automatically", isOn: $autoReconnect)
            }

            Section("Privacy") {
                Toggle("Sync clipboard content marked sensitive", isOn: $allowSensitive)
                Text(
                    "Sensitive content is never written to disk or kept in history. "
                    + "Leaving this off is the safer default."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Startup") {
                LabeledContent("Launch at login") {
                    Text("Available in M4")
                        .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                LabeledContent("Version", value: BuildInfo.appVersion)
                LabeledContent("Build", value: BuildInfo.buildNumber)
                LabeledContent("macOS", value: BuildInfo.operatingSystem)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
