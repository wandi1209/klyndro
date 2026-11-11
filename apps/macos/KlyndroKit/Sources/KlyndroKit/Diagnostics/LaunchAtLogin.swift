import Foundation
import ServiceManagement

/// Manages launch-at-login via `SMAppService.mainApp` on macOS 13+.
///
/// Isolated so UI components can check and toggle the system state without
/// directly dealing with ServiceManagement exceptions.
@MainActor
public final class LaunchAtLogin {
    public static let shared = LaunchAtLogin()

    private init() {}

    public var isAvailable: Bool {
        // SMAppService.mainApp is only valid for packaged application bundles.
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else { return }
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
