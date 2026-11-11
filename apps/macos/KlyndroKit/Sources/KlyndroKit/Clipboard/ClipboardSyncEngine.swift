import Foundation

/// A snapshot of the local pasteboard.
public struct ClipboardSnapshot: Sendable, Equatable {
    public var text: String
    public var sensitive: Bool
    /// Local monotonic value from the platform, used to detect "nothing changed".
    public var changeCount: Int

    public init(text: String, sensitive: Bool, changeCount: Int) {
        self.text = text
        self.sensitive = sensitive
        self.changeCount = changeCount
    }
}

/// What the engine decided to do with an outbound change.
public enum ClipboardOutbound: Sendable, Equatable {
    case send(ClipboardUpdateBody)
    case suppress(ClipboardSuppressionReason)
}

public enum ClipboardSuppressionReason: String, Sendable, Equatable {
    /// Clipboard sync is switched off.
    case disabled
    /// Nothing to send.
    case empty
    /// The same text was already sent.
    case duplicate
    /// This is our own write of remote content coming back from the pasteboard.
    case echoOfRemote
    /// The item is marked sensitive and sensitive sync is off.
    case sensitive
    /// Over `ClipboardMessageCodec.maximumTextBytes`.
    case tooLarge
}

/// What the engine decided to do with inbound content.
public enum ClipboardInbound: Sendable, Equatable {
    case apply(String)
    case ignore(ClipboardIgnoreReason)
}

public enum ClipboardIgnoreReason: String, Sendable, Equatable {
    /// This device produced the content; echoing it back would loop.
    case ownOrigin
    /// Already applied.
    case duplicate
    /// Older than what we already applied on this session.
    case stale
    /// Sync is off.
    case disabled
    case unsupportedType
    /// Marked sensitive while sensitive sync is off.
    case sensitive
}

/// Decides what crosses the clipboard boundary. Pure logic: no pasteboard, no sockets.
///
/// Loop prevention is the whole point of this type. When remote content is written to the local
/// pasteboard, the local monitor notices a change and wants to send it straight back. Three
/// independent rules stop that:
///
/// 1. `originID` — never re-send content this device originated.
/// 2. `lastAppliedRemoteHash` within a short window — that change *is* our own write.
/// 3. `lastSeenHash` — whatever the local pasteboard currently holds is never sent back,
///    whether it was copied locally or applied from the peer. This is what makes the loop
///    terminate even when the pasteboard reports our write long after the window.
public struct ClipboardSyncEngine: Sendable {
    /// How long after applying remote content a matching local change is treated as our own
    /// write. Pasteboards deliver change notifications with a small delay, so this cannot be zero.
    public static let echoSuppressionWindow: TimeInterval = 2.0

    public var isEnabled: Bool
    public var allowsSensitive: Bool
    /// Identifies this device as the origin of content it produced.
    public let deviceID: DeviceID

    private var changeCounter = 0
    /// Hash of the content the local pasteboard currently holds, from either direction.
    private var lastSeenHash: String?
    private var lastAppliedRemoteHash: String?
    private var lastAppliedAt: Date?
    private var lastAppliedCounterByOrigin: [String: Int] = [:]
    private var lastLocalChangeCount: Int?

    public init(deviceID: DeviceID, isEnabled: Bool = true, allowsSensitive: Bool = false) {
        self.deviceID = deviceID
        self.isEnabled = isEnabled
        self.allowsSensitive = allowsSensitive
    }

    // MARK: - Outbound

    /// Evaluates a local pasteboard snapshot.
    public mutating func outbound(
        _ snapshot: ClipboardSnapshot,
        now: Date = Date()
    ) -> ClipboardOutbound {
        guard isEnabled else { return .suppress(.disabled) }

        // Polling can observe the same platform change twice; only new content counts.
        if let lastCount = lastLocalChangeCount, snapshot.changeCount == lastCount {
            return .suppress(.duplicate)
        }
        lastLocalChangeCount = snapshot.changeCount

        let text = snapshot.text
        guard !text.isEmpty else { return .suppress(.empty) }

        // Check bytes, not characters: the limit is about bytes on the wire.
        let byteCount = text.utf8.count
        guard byteCount <= ClipboardMessageCodec.maximumTextBytes else {
            return .suppress(.tooLarge)
        }

        if snapshot.sensitive && !allowsSensitive {
            return .suppress(.sensitive)
        }

        let hash = ClipboardMessageCodec.hash(of: text)

        // Our own write of remote content, observed by the local pasteboard.
        if let appliedAt = lastAppliedAt,
           lastAppliedRemoteHash == hash,
           now.timeIntervalSince(appliedAt) <= Self.echoSuppressionWindow {
            return .suppress(.echoOfRemote)
        }

        // Already the pasteboard's content: either we sent it, or it came from the peer and must
        // not be bounced back even after the echo window has passed.
        if hash == lastSeenHash {
            return .suppress(.duplicate)
        }

        lastSeenHash = hash
        changeCounter += 1

        return .send(
            ClipboardUpdateBody(
                text: text,
                hash: hash,
                changeCount: changeCounter,
                originID: deviceID,
                sensitive: snapshot.sensitive
            )
        )
    }

    // MARK: - Inbound

    /// Decides whether inbound content should be written to the local pasteboard.
    public mutating func inbound(
        _ body: ClipboardUpdateBody,
        now: Date = Date()
    ) -> ClipboardInbound {
        guard isEnabled else { return .ignore(.disabled) }
        guard body.contentType == .plainText else { return .ignore(.unsupportedType) }
        guard body.originID != deviceID else { return .ignore(.ownOrigin) }

        if body.sensitive && !allowsSensitive {
            return .ignore(.sensitive)
        }

        // Stale content from before a reconnect must not overwrite newer text.
        if let lastCounter = lastAppliedCounterByOrigin[body.originID.hex],
           body.changeCount <= lastCounter {
            return .ignore(.stale)
        }

        if body.hash == lastAppliedRemoteHash {
            return .ignore(.duplicate)
        }

        lastAppliedRemoteHash = body.hash
        lastAppliedAt = now
        lastSeenHash = body.hash
        lastAppliedCounterByOrigin[body.originID.hex] = body.changeCount

        return .apply(body.text)
    }

    /// Records a write of remote content so the resulting local change is recognised as an echo
    /// even when the pasteboard reports it later than `inbound` was called.
    public mutating func noteApplied(_ body: ClipboardUpdateBody, at date: Date = Date()) {
        lastAppliedRemoteHash = body.hash
        lastAppliedAt = date
        lastSeenHash = body.hash
        lastAppliedCounterByOrigin[body.originID.hex] = body.changeCount
    }

    /// Called on reconnect: per-origin counters are session state, not history.
    public mutating func resetSessionState() {
        lastAppliedCounterByOrigin.removeAll()
        lastAppliedRemoteHash = nil
        lastAppliedAt = nil
        lastLocalChangeCount = nil
        // `lastSeenHash` and `changeCounter` intentionally survive: they describe what the
        // pasteboard holds and what this device has produced, so a reconnect does not
        // immediately re-send the text that is already on both sides.
    }

    /// For tests and diagnostics.
    public var currentChangeCounter: Int { changeCounter }
}
