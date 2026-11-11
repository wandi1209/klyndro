import Foundation

public enum MirroringState: Sendable, Equatable {
    case idle
    case starting
    case running
    case stopping
    /// Carries the last stderr lines so the UI can say *why*.
    case failed(reason: String)

    public var isActive: Bool {
        switch self {
        case .starting, .running, .stopping: return true
        case .idle, .failed: return false
        }
    }
}

/// Fixed-size window over the most recent lines. scrcpy prints serials and warnings, never
/// clipboard content, but an unbounded buffer is still a leak waiting to happen.
public struct LineRingBuffer: Sendable, Equatable {
    public private(set) var lines: [String] = []
    public let capacity: Int
    private var partial = ""

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ chunk: String) {
        partial += chunk
        var pieces = partial.components(separatedBy: "\n")
        partial = pieces.removeLast()
        for piece in pieces {
            let line = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }

    /// Lines plus any trailing text that never got a newline (a crash can end mid-line).
    public var snapshot: [String] {
        let tail = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? lines : lines + [tail]
    }
}

/// Runs one scrcpy child process and reports its real state.
///
/// State comes from `Process.isRunning` and `terminationHandler`; it is never inferred from
/// the fact that `run()` once succeeded.
public final class MirroringSession: @unchecked Sendable {
    public static let logCapacity = 200
    public static let gracePeriod: TimeInterval = 5

    private let lock = NSLock()
    private var process: Process?
    private var log = LineRingBuffer(capacity: MirroringSession.logCapacity)
    private var currentState: MirroringState = .idle
    private var stopRequested = false
    private var onChange: (@Sendable (MirroringState) -> Void)?

    public init() {}

    public var state: MirroringState { lock.withLock { currentState } }
    public var recentLog: [String] { lock.withLock { log.snapshot } }

    public func setObserver(_ observer: (@Sendable (MirroringState) -> Void)?) {
        lock.withLock { onChange = observer }
    }

    /// Starts the child. Returns an error string when it cannot even launch.
    @discardableResult
    public func start(_ invocation: ScrcpyCommand.Invocation) -> String? {
        let alreadyActive = lock.withLock { currentState.isActive }
        if alreadyActive { return "Mirroring is already running." }

        guard FileManager.default.isExecutableFile(atPath: invocation.executable) else {
            transition(to: .failed(reason: "scrcpy was not found at \(invocation.executable)."))
            return "scrcpy was not found."
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: invocation.executable)
        child.arguments = invocation.arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in invocation.environment { environment[key] = value }
        child.environment = environment

        let errorPipe = Pipe()
        child.standardError = errorPipe
        child.standardOutput = Pipe()
        child.standardInput = FileHandle.nullDevice

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.withLock { self.log.append(text) }
        }

        child.terminationHandler = { [weak self] finished in
            errorPipe.fileHandleForReading.readabilityHandler = nil
            self?.handleTermination(status: finished.terminationStatus, reason: finished.terminationReason)
        }

        lock.withLock {
            log = LineRingBuffer(capacity: Self.logCapacity)
            stopRequested = false
            process = child
        }
        transition(to: .starting)

        do {
            try child.run()
        } catch {
            lock.withLock { process = nil }
            transition(to: .failed(reason: "Could not launch scrcpy: \(error.localizedDescription)"))
            return "Could not launch scrcpy."
        }

        // scrcpy opens its window a moment after launch; a process that is still alive after
        // this short settle is treated as running, and a quick exit is reported as a failure
        // by `handleTermination`.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let stillStarting = self.lock.withLock { self.currentState == .starting && (self.process?.isRunning ?? false) }
            if stillStarting { self.transition(to: .running) }
        }
        return nil
    }

    /// SIGTERM, then SIGKILL after the grace period. Never leaves an orphan behind.
    public func stop() {
        let child: Process? = lock.withLock {
            guard let process, process.isRunning else { return nil }
            stopRequested = true
            return process
        }
        guard let child else { return }

        transition(to: .stopping)
        child.terminate()

        DispatchQueue.global().asyncAfter(deadline: .now() + Self.gracePeriod) { [weak self] in
            guard child.isRunning else { return }
            kill(child.processIdentifier, SIGKILL)
            self?.lock.withLock { self?.log.append("scrcpy ignored SIGTERM and was killed.\n") }
        }
    }

    private func handleTermination(status: Int32, reason: Process.TerminationReason) {
        let wasRequested = lock.withLock { () -> Bool in
            process = nil
            return stopRequested
        }

        if wasRequested || status == 0 {
            transition(to: .idle)
            return
        }

        let tail = recentLog.suffix(3).joined(separator: " ")
        let detail = tail.isEmpty ? "scrcpy exited with status \(status)." : tail
        transition(to: .failed(reason: detail))
    }

    private func transition(to next: MirroringState) {
        let observer = lock.withLock { () -> (@Sendable (MirroringState) -> Void)? in
            currentState = next
            return onChange
        }
        observer?(next)
    }
}
