import AppKit
import SwiftUI

/// Receives `klyndro://` links, which is how "start pairing" can be triggered from a shortcut,
/// a script, or a future URL-based flow.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once at launch; the delegate exists before the model is constructed.
    @MainActor static weak var model: AppModel?

    @MainActor
    static func setModel(_ model: AppModel) {
        Self.model = model
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model = Self.model else { return }
        for url in urls where url.scheme == "klyndro" {
            Task { await model.handle(url: url) }
        }
    }
}

@main
struct KlyndroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // A menu bar agent must be listening before the user opens the menu.
        Task {
            await AppDelegate.setModel(model)
            await model.start()
        }
    }

    var body: some Scene {
        MenuBarExtra("Klyndro", systemImage: "link") {
            MenuBarView()
                .environment(model)
        }

        Window("Klyndro", id: "main") {
            MainWindowView()
                .environment(model)
        }
        .defaultSize(width: 780, height: 600)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
