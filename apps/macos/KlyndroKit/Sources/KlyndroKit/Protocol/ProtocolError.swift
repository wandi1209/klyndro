import Foundation

/// Errors a peer can cause, or that we can detect locally while decoding.
///
/// Cases deliberately carry no payload content: these values end up in logs, and
/// clipboard text must never be logged (§11).
public enum ProtocolError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The length field exceeded `FramingLimits.maxFrameBytes`.
    case frameTooLarge(Int)
    /// The length field was zero, so there is no kind byte.
    case emptyFrame
    /// The peer used a frame kind this implementation does not support.
    case unsupportedFrameKind(UInt8)
    /// A control message arrived in a non-envelope frame kind.
    case wrongFrameKind
    /// JSON was not an object, a required field was missing or mistyped, or the id was not a UUID.
    case malformedEnvelope(String)
    /// The envelope version is not `Envelope.currentVersion`.
    case unsupportedVersion(Int)
    /// A syntactically valid message type that this build does not implement.
    case unknownMessageType(String)

    public var description: String {
        switch self {
        case .frameTooLarge(let bytes):
            return "frame too large (\(bytes) bytes)"
        case .emptyFrame:
            return "empty frame"
        case .unsupportedFrameKind(let raw):
            return "unsupported frame kind 0x\(String(raw, radix: 16))"
        case .wrongFrameKind:
            return "expected an envelope frame"
        case .malformedEnvelope(let reason):
            return "malformed envelope: \(reason)"
        case .unsupportedVersion(let version):
            return "unsupported protocol version \(version)"
        case .unknownMessageType(let type):
            return "unknown message type '\(type)'"
        }
    }
}
