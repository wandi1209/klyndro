import Foundation

/// Structured, allowlisted ADB actions for Advanced Mode (ADR 0010).
/// Every action builds an explicit `Process` argument array and never accepts arbitrary shell text.
public enum AdbNavKey: String, CaseIterable, Sendable {
    case back
    case home
    case recents
    case power

    public var keyEventArgument: String {
        switch self {
        case .back: return "KEYCODE_BACK"
        case .home: return "KEYCODE_HOME"
        case .recents: return "KEYCODE_APP_SWITCH"
        case .power: return "KEYCODE_POWER"
        }
    }

    public var displayName: String {
        switch self {
        case .back: return "Back"
        case .home: return "Home"
        case .recents: return "Recents"
        case .power: return "Power"
        }
    }
}

public struct AdbPackageName: Equatable, Hashable, Sendable {
    public let value: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255, !trimmed.hasPrefix("-") else { return nil }
        let segments = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        let valid = segments.allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy { ch in
                ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_")
            }
        }
        guard valid else { return nil }
        self.value = trimmed
    }
}

public enum AdbPackagesParser {
    public static func parse(_ output: String) -> [AdbPackageName] {
        var seen = Set<String>()
        var result: [AdbPackageName] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("package:") else { continue }
            let pkgRaw = String(line.dropFirst("package:".count))
            guard let pkg = AdbPackageName(pkgRaw), seen.insert(pkg.value).inserted else { continue }
            result.append(pkg)
        }
        return result.sorted { $0.value < $1.value }
    }
}

public enum AdbControlCommand {
    public static func keyEventArguments(serial: String, key: AdbNavKey) -> [String] {
        ["-s", serial, "shell", "input", "keyevent", key.keyEventArgument]
    }

    public static func listPackagesArguments(serial: String) -> [String] {
        ["-s", serial, "shell", "pm", "list", "packages", "-3"]
    }

    public static func launchPackageArguments(serial: String, package: AdbPackageName) -> [String] {
        ["-s", serial, "shell", "monkey", "-p", package.value, "-c", "android.intent.category.LAUNCHER", "1"]
    }

    public static func screencapArguments(serial: String) -> [String] {
        ["-s", serial, "exec-out", "screencap", "-p"]
    }

    /// Runs a binary command and returns raw stdout bytes (used for `adb exec-out screencap -p`).
    public static func captureData(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning { process.terminate() }
        }
        timer.resume()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}
