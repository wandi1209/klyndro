import Foundation
import Network

/// An IPv4 `host:port` pair that is safe to hand to `adb` as a single argument.
///
/// Validation is strict on purpose: the value comes from user input (pairing) or from the
/// network (Bonjour), and `adb` treats a leading `-` as a flag.
public struct AdbEndpoint: Sendable, Equatable, Hashable {
    public let host: String
    public let port: UInt16

    public var address: String { "\(host):\(port)" }

    public init?(host: String, port: UInt16) {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard port > 0, octets.count == 4,
              octets.allSatisfy({ octet in
                  !octet.isEmpty && octet.count <= 3
                      && octet.allSatisfy { $0.isASCII && $0.isNumber }
                      && (Int(octet).map { $0 <= 255 } ?? false)
              })
        else { return nil }
        self.host = host
        self.port = port
    }

    /// Parses `192.168.1.20:37171`.
    public init?(address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.lastIndex(of: ":"),
              let port = UInt16(trimmed[trimmed.index(after: separator)...])
        else { return nil }
        self.init(host: String(trimmed[trimmed.startIndex..<separator]), port: port)
    }
}

/// The six-digit code shown by Android's "Pair device with pairing code" dialog.
public struct AdbPairingCode: Sendable, Equatable {
    public let value: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        self.value = trimmed
    }
}

public enum AdbWirelessResult: Sendable, Equatable {
    case success(String)
    case failure(String)
}

/// Reads the human-oriented output of `adb connect` and `adb pair`. Pure, so every phrasing
/// is testable without a phone.
public enum AdbWirelessParser {
    public static func parseConnect(_ output: String) -> AdbWirelessResult {
        let line = firstMeaningfulLine(output)
        let lowered = line.lowercased()
        if lowered.contains("failed") || lowered.contains("cannot") || lowered.contains("unable") {
            return .failure(line)
        }
        if lowered.contains("connected to") { return .success(line) }
        return .failure(line.isEmpty ? "adb printed nothing" : line)
    }

    public static func parsePair(_ output: String) -> AdbWirelessResult {
        let line = firstMeaningfulLine(output)
        if line.lowercased().contains("successfully paired") { return .success(line) }
        return .failure(line.isEmpty ? "adb printed nothing" : line)
    }

    private static func firstMeaningfulLine(_ output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
        return String(lines.first?.prefix(200) ?? "")
    }
}

/// Runs a short-lived tool and returns its combined output. Blocking: call off the main actor.
public enum AdbProcess {
    public struct Output: Sendable, Equatable {
        public var status: Int32
        public var text: String
        public var timedOut: Bool
    }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return Output(status: -1, text: "could not launch \(executable): \(error.localizedDescription)", timedOut: false)
        }

        let flag = TimeoutFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                flag.set()
                process.terminate()
            }
        }

        // Read before waiting: a full pipe would otherwise block the child forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            text: String(decoding: data, as: UTF8.self),
            timedOut: flag.isSet
        )
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }
}

/// Android 11+ "Wireless debugging" advertises its connect port over Bonjour. The port changes
/// whenever the feature is toggled, so reading it here is what removes the need to type it.
public enum WirelessAdbDiscovery {
    public static let connectServiceType = "_adb-tls-connect._tcp"

    /// Finds phones offering Wireless debugging. Only a plain TCP connect is made to learn the
    /// resolved address; `adb connect` still needs a key the phone already trusts.
    public static func scanConnectEndpoints(duration: TimeInterval = 3) async -> [AdbEndpoint] {
        let found = await browse(duration: duration)
        var endpoints: [AdbEndpoint] = []
        for endpoint in found {
            if let resolved = await EndpointResolver.resolve(endpoint), !endpoints.contains(resolved) {
                endpoints.append(resolved)
            }
        }
        return endpoints
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var endpoints: [NWEndpoint] = []
        func set(_ value: [NWEndpoint]) { lock.lock(); endpoints = value; lock.unlock() }
        func get() -> [NWEndpoint] { lock.lock(); defer { lock.unlock() }; return endpoints }
    }

    private static func browse(duration: TimeInterval) async -> [NWEndpoint] {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "id.my.wandidev.klyndro.adb-browse")
            let collected = Collected()
            let browser = NWBrowser(for: .bonjour(type: connectServiceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { results, _ in
                collected.set(results.map(\.endpoint))
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + duration) {
                browser.cancel()
                continuation.resume(returning: collected.get())
            }
        }
    }
}

private final class EndpointResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<AdbEndpoint?, Never>

    private init(endpoint: NWEndpoint, continuation: CheckedContinuation<AdbEndpoint?, Never>) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.continuation = continuation
    }

    static func resolve(_ endpoint: NWEndpoint) async -> AdbEndpoint? {
        await withCheckedContinuation { continuation in
            let resolver = EndpointResolver(endpoint: endpoint, continuation: continuation)
            resolver.start()
        }
    }

    private func start() {
        let queue = DispatchQueue(label: "id.my.wandidev.klyndro.adb-resolve")
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                    // Drop an interface scope such as "%en0".
                    let plain = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                    finish(AdbEndpoint(host: plain, port: port.rawValue))
                } else {
                    finish(nil)
                }
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [self] in finish(nil) }
    }

    private func finish(_ value: AdbEndpoint?) {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        guard first else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: value)
    }
}
