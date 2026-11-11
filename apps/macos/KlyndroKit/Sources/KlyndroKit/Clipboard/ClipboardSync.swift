import Foundation

/// Orchestrates clipboard sync for one connected peer.
///
/// Separates three concerns that are easy to tangle: reading the local pasteboard, deciding what
/// crosses the wire (`ClipboardSyncEngine`), and sending/receiving over a session. Main-actor
/// isolated because the pasteboard is, and because every call here is short and non-blocking.
@MainActor
public final class ClipboardSync {
    private var engine: ClipboardSyncEngine
    private let pasteboard: Pasteboard
    private let monitor: PasteboardMonitor?
    private weak var session: PeerSession?

    public private(set) var isRunning = false
    public private(set) var lastError: String?
    /// Counts for the UI, so "clipboard sync is on" is backed by something observable.
    public private(set) var sentCount = 0
    public private(set) var appliedCount = 0

    public init(
        deviceID: DeviceID,
        pasteboard: Pasteboard,
        monitor: PasteboardMonitor?,
        session: PeerSession,
        isEnabled: Bool,
        allowsSensitive: Bool
    ) {
        self.engine = ClipboardSyncEngine(
            deviceID: deviceID,
            isEnabled: isEnabled,
            allowsSensitive: allowsSensitive
        )
        self.pasteboard = pasteboard
        self.monitor = monitor
        self.session = session
    }

    public func setEnabled(_ enabled: Bool) {
        engine.isEnabled = enabled
        if !enabled {
            monitor?.stop()
        } else if isRunning {
            monitor?.start()
        }
    }

    public func setAllowsSensitive(_ allowed: Bool) {
        engine.allowsSensitive = allowed
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        engine.resetSessionState()
        monitor?.start()
    }

    public func stop() {
        isRunning = false
        monitor?.stop()
    }

    /// Handles a local pasteboard change: decide, then send.
    public func localClipboardChanged(_ snapshot: ClipboardSnapshot) async {
        switch engine.outbound(snapshot) {
        case .suppress:
            break
        case .send(let body):
            await send(body)
        }
    }

    /// Handles an inbound update: decide, then apply to the local pasteboard.
    public func remoteClipboardChanged(_ body: ClipboardUpdateBody, refID: String) async {
        switch engine.inbound(body) {
        case .ignore(let reason):
            // Only genuine refusals are acknowledged. Duplicates and our own content are normal
            // traffic and must not generate ack noise.
            if let reject = reason.asRejectReason {
                await sendAck(ClipboardAckBody(refID: refID, accepted: false, reason: reject))
            }
        case .apply(let text):
            pasteboard.write(text: text)
            engine.noteApplied(body)
            // Our own write must not look like a local copy.
            monitor?.markCurrentAsSeen()
            appliedCount += 1
            await sendAck(ClipboardAckBody(refID: refID, accepted: true))
        }
    }

    private func send(_ body: ClipboardUpdateBody) async {
        guard let session else { return }
        do {
            try await session.send(ClipboardMessageCodec.updateEnvelope(body))
            sentCount += 1
        } catch {
            lastError = String(describing: error)
        }
    }

    private func sendAck(_ body: ClipboardAckBody) async {
        guard let session else { return }
        try? await session.send(ClipboardMessageCodec.ackEnvelope(body))
    }
}

extension ClipboardIgnoreReason {
    /// The reason to report to the peer, or `nil` when nothing should be reported.
    var asRejectReason: ClipboardRejectReason? {
        switch self {
        case .sensitive: return .sensitive
        case .unsupportedType: return .unsupportedType
        case .disabled: return .disabled
        case .duplicate, .stale, .ownOrigin: return nil
        }
    }
}
