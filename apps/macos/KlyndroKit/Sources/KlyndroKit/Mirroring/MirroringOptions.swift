import Foundation

/// User-facing mirroring settings. Defaults favour privacy: no audio, screen stays as it is.
public struct MirroringOptions: Sendable, Equatable {
    /// Cap on the longer edge, in pixels. `nil` lets scrcpy pick the device resolution.
    public var maxSize: Int?
    public var maxFPS: Int?
    /// Turn the phone's own display off while mirroring continues.
    public var turnScreenOff: Bool
    /// View-only: no keyboard or mouse injection.
    public var viewOnly: Bool
    public var stayAwake: Bool

    public init(
        maxSize: Int? = nil,
        maxFPS: Int? = nil,
        turnScreenOff: Bool = false,
        viewOnly: Bool = false,
        stayAwake: Bool = false
    ) {
        self.maxSize = maxSize
        self.maxFPS = maxFPS
        self.turnScreenOff = turnScreenOff
        self.viewOnly = viewOnly
        self.stayAwake = stayAwake
    }

    public static let `default` = MirroringOptions()

    /// Bounds mirror what scrcpy accepts; out-of-range values are dropped rather than passed on,
    /// so a corrupt preference cannot turn into a confusing scrcpy error.
    public static let sizeRange = 240...4096
    public static let fpsRange = 1...120
}

/// Builds the child-process invocation. Everything is an argument array, never a shell string:
/// device names and serials are untrusted input (docs/architecture/mirroring.md).
public enum ScrcpyCommand {
    public struct Invocation: Sendable, Equatable {
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]
    }

    public static func make(
        scrcpyPath: String,
        adbPath: String,
        serial: String,
        windowTitle: String,
        options: MirroringOptions,
        baseEnvironment: [String: String] = [:]
    ) -> Invocation {
        var arguments = ["--serial=\(serial)", "--window-title=\(windowTitle)", "--no-audio"]

        if let size = options.maxSize, MirroringOptions.sizeRange.contains(size) {
            arguments.append("--max-size=\(size)")
        }
        if let fps = options.maxFPS, MirroringOptions.fpsRange.contains(fps) {
            arguments.append("--max-fps=\(fps)")
        }
        if options.turnScreenOff { arguments.append("--turn-screen-off") }
        if options.viewOnly { arguments.append("--no-control") }
        if options.stayAwake { arguments.append("--stay-awake") }

        // A GUI-launched app inherits a minimal PATH, so scrcpy would not find adb on its own.
        var environment = baseEnvironment
        environment["ADB"] = adbPath

        return Invocation(executable: scrcpyPath, arguments: arguments, environment: environment)
    }
}
