import Foundation

/// Audio routing for Advanced Mode (`scrcpy`).
public enum MirrorAudioMode: String, CaseIterable, Identifiable, Sendable {
    /// Keep audio on the phone speaker only (`--no-audio`).
    case phoneOnly = "phone_only"
    /// Route audio to Mac and mute the phone speaker (Android 11+).
    case macOnly = "mac_only"
    /// Play audio on both Mac and phone (Android 13+, `--audio-source=playback --audio-dup`).
    case both = "both"
    /// Mute audio on both devices (`--no-audio-playback`, Android 11+).
    case disabled = "disabled"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .phoneOnly: return "Phone only"
        case .macOnly: return "Mac only (mute phone)"
        case .both: return "Mac + Phone"
        case .disabled: return "Mute both"
        }
    }

    public var scrcpyFlags: [String] {
        switch self {
        case .phoneOnly: return ["--no-audio"]
        case .macOnly: return []
        case .both: return ["--audio-source=playback", "--audio-dup"]
        case .disabled: return ["--no-audio-playback"]
        }
    }
}

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
    public var audioMode: MirrorAudioMode

    public init(
        maxSize: Int? = nil,
        maxFPS: Int? = nil,
        turnScreenOff: Bool = false,
        viewOnly: Bool = false,
        stayAwake: Bool = false,
        audioMode: MirrorAudioMode = .phoneOnly
    ) {
        self.maxSize = maxSize
        self.maxFPS = maxFPS
        self.turnScreenOff = turnScreenOff
        self.viewOnly = viewOnly
        self.stayAwake = stayAwake
        self.audioMode = audioMode
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
        var arguments = ["--serial=\(serial)", "--window-title=\(windowTitle)"]
        arguments.append(contentsOf: options.audioMode.scrcpyFlags)

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
