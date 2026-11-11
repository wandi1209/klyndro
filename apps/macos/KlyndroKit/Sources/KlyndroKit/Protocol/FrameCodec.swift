import Foundation

/// Length-prefixed framing, Klyndro Protocol v1 §3.
///
/// Reads arrive as an arbitrary byte stream: one `read()` may contain half a frame or
/// five frames. `FrameDecoder` is a pure value type so it can be tested without sockets.
public enum FrameEncoder {
    /// Encodes a frame, enforcing the wire limit before producing bytes.
    public static func encode(_ frame: Frame) throws -> Data {
        let length = frame.payload.count + 1
        guard length <= FramingLimits.maxFrameBytes else {
            throw ProtocolError.frameTooLarge(length)
        }

        var data = Data(capacity: FramingLimits.headerBytes + frame.payload.count)
        data.append(UInt8((length >> 24) & 0xFF))
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(frame.kind.rawValue)
        data.append(frame.payload)
        return data
    }
}

/// Streaming frame decoder. Feed it bytes as they arrive, pull complete frames out.
public struct FrameDecoder {
    private var buffer: [UInt8] = []

    public init() {}

    /// Number of bytes buffered but not yet consumed. Useful for diagnostics.
    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// Returns the next complete frame, or `nil` if more bytes are required.
    ///
    /// Throws on protocol violations. The caller must treat a throw as fatal for the
    /// connection: a length or kind we cannot interpret means we cannot resynchronise.
    public mutating func nextFrame() throws -> Frame? {
        guard buffer.count >= 4 else { return nil }

        let length = (Int(buffer[0]) << 24)
            | (Int(buffer[1]) << 16)
            | (Int(buffer[2]) << 8)
            | Int(buffer[3])

        // Reject an impossible length as soon as the prefix is readable. Waiting for a
        // fifth byte a hostile peer may never send would be a trivial stall.
        guard length >= 1 else { throw ProtocolError.emptyFrame }
        guard length <= FramingLimits.maxFrameBytes else {
            throw ProtocolError.frameTooLarge(length)
        }
        guard buffer.count >= 4 + length else { return nil }

        let rawKind = buffer[4]
        guard let kind = FrameKind(rawValue: rawKind) else {
            throw ProtocolError.unsupportedFrameKind(rawKind)
        }

        let payload = Data(buffer[5..<(4 + length)])
        buffer.removeFirst(4 + length)
        return Frame(kind: kind, payload: payload)
    }
}
