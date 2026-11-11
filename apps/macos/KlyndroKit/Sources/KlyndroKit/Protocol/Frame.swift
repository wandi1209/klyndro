import Foundation

/// Frame kind byte, Klyndro Protocol v1 §3.
///
/// `0x02` is reserved for file chunks and is intentionally not modelled yet: the chunk
/// header is not specified until M5, and accepting a frame we cannot parse would be
/// worse than rejecting it.
public enum FrameKind: UInt8, Sendable, CaseIterable {
    case envelope = 0x01
}

/// A single protocol frame: a kind byte plus its payload.
public struct Frame: Sendable, Equatable {
    public var kind: FrameKind
    public var payload: Data

    public init(kind: FrameKind, payload: Data) {
        self.kind = kind
        self.payload = payload
    }
}

/// Wire limits from Klyndro Protocol v1 §10. These are hard bounds, checked before any
/// allocation or decoding happens.
public enum FramingLimits {
    /// Maximum value of the 4-byte length field, which includes the kind byte.
    public static let maxFrameBytes = 1_048_576
    /// Maximum JSON payload of a single envelope.
    public static let maxEnvelopeBytes = 1_048_576
    /// Length prefix (4 bytes) + kind byte (1 byte).
    public static let headerBytes = 5
    /// Maximum number of bytes that may follow the kind byte.
    public static let maxPayloadBytes = maxFrameBytes - 1
}
