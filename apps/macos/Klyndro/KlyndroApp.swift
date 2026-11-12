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

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model = Self.model else { return }
        Task { @MainActor in
            await model.start()
        }
    }

    // Quitting must not leave a scrcpy window (and its adb server process) running unattended.
    func applicationWillTerminate(_ notification: Notification) {
        guard let model = Self.model else { return }
        MainActor.assumeIsolated { model.shutDown() }
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
        let m = AppModel()
        _model = State(initialValue: m)
        AppDelegate.setModel(m)
        Task { @MainActor in
            await m.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .task {
                    AppDelegate.setModel(model)
                    await model.start()
                }
        } label: {
            Image("MenuBarIcon")
        }

        Window("Klyndro", id: "main") {
            MainWindowView()
                .environment(model)
        }
        .defaultSize(width: 780, height: 600)
        .windowResizability(.contentMinSize)

        Window("Phone Screen (Standard)", id: "standard-mirror") {
            StandardMirrorView()
                .environment(model)
        }
        .defaultSize(width: 420, height: 820)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
