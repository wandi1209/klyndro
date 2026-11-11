import Foundation

/// One external executable Klyndro depends on.
public struct Tool: Identifiable, Sendable, Equatable {
    public let name: String
    public let purpose: String
    public let required: Bool
    public let path: String?
    public let version: String?

    public var id: String { name }

    public var isAvailable: Bool { path != nil }

    public init(name: String, purpose: String, required: Bool, path: String?, version: String?) {
        self.name = name
        self.purpose = purpose
        self.required = required
        self.path = path
        self.version = version
    }
}

/// Result of probing the local toolchain, surfaced in the UI so users can see *why*
/// mirroring is unavailable instead of getting a silent failure.
public struct ToolchainReport: Sendable, Equatable {
    public var tools: [Tool]
    public var generatedAt: Date

    public init(tools: [Tool], generatedAt: Date) {
        self.tools = tools
        self.generatedAt = generatedAt
    }

    public var missingRequired: [Tool] { tools.filter { $0.required && !$0.isAvailable } }
    public var missingOptional: [Tool] { tools.filter { !$0.required && !$0.isAvailable } }
}

/// Locates the external binaries Klyndro drives.
///
/// A GUI app launched from Finder inherits a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`),
/// so Homebrew locations are searched explicitly. This is the most common reason
/// "mirroring does nothing" on a machine where the terminal has `scrcpy` available.
public enum ToolchainProbe {
    /// Runs off the main actor: spawning processes and reading pipes block.
    public static func probe() async -> ToolchainReport {
        await Task.detached(priority: .utility) {
            generate()
        }.value
    }

    public static func generate() -> ToolchainReport {
        let specs: [(name: String, purpose: String, required: Bool)] = [
            ("adb", "Device transport for screen mirroring", true),
            ("scrcpy", "Mirroring engine (launched as a child process)", false)
        ]

        let tools = specs.map { spec in
            let path = locate(spec.name)
            return Tool(
                name: spec.name,
                purpose: spec.purpose,
                required: spec.required,
                path: path,
                version: path.flatMap { firstVersionLine(of: $0) }
            )
        }

        return ToolchainReport(tools: tools, generatedAt: Date())
    }

    /// Returns the absolute path of `executable`, or `nil` when it is not on the search path.
    public static func locate(
        _ executable: String,
        searchPath: String? = nil,
        fileManager: FileManager = .default
    ) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let rawPath = searchPath ?? environment["PATH"] ?? ""

        var directories = rawPath.split(separator: ":").map(String.init)
        directories.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])

        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory)
                .appending(path: executable)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func firstVersionLine(of path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return summarizeVersionOutput(String(decoding: data, as: UTF8.self))
    }

    /// Keeps only the first non-empty line, capped: usage dumps are not version strings.
    static func summarizeVersionOutput(_ output: String) -> String? {
        let line = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }

        guard let line else { return nil }
        return String(line.prefix(120))
    }
}
