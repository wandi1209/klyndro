import Foundation

/// `UserDefaults` keys shared by the menu bar and the settings window.
///
/// Values are user intent. Whether a capability is *implemented* is tracked in
/// `docs/testing/verification-status.md`, not inferred from a preference being on.
enum PreferenceKeys {
    static let clipboardSyncEnabled = "clipboardSyncEnabled"
    static let notificationsEnabled = "notificationsEnabled"
    static let autoReconnect = "autoReconnect"
    static let launchAtLogin = "launchAtLogin"
    static let allowSensitiveClipboard = "allowSensitiveClipboard"
    static let mirroringMode = "mirroringMode"
    static let standardAudioEnabled = "standardAudioEnabled"
}

enum MirroringMode: String, CaseIterable, Identifiable {
    case standard
    case advanced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard (No ADB)"
        case .advanced: return "Advanced (ADB / scrcpy)"
        }
    }
}

enum BuildInfo {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var operatingSystem: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static var summary: String {
        "Klyndro \(appVersion) (\(buildNumber)) · macOS \(operatingSystem)"
    }
}
