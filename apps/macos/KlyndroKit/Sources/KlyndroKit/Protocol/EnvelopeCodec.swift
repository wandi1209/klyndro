import Foundation

/// Envelope encode/decode with the validation order mandated by Klyndro Protocol v1 §4.
public enum EnvelopeCodec {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Deterministic bytes make fixtures and logs comparable across runs.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// Encodes an envelope to its JSON payload (no length prefix).
    public static func encode(_ envelope: Envelope) throws -> Data {
        let data = try makeEncoder().encode(envelope)
        guard data.count <= FramingLimits.maxEnvelopeBytes else {
            throw ProtocolError.frameTooLarge(data.count)
        }
        return data
    }

    /// Encodes an envelope straight to a wire-ready frame.
    public static func frame(for envelope: Envelope) throws -> Frame {
        Frame(kind: .envelope, payload: try encode(envelope))
    }

    /// Validates and decodes a JSON payload.
    ///
    /// Failure reasons are safe to log: they name a field at most, never a value.
    public static func decode(payload: Data) throws -> Envelope {
        guard payload.count <= FramingLimits.maxEnvelopeBytes else {
            throw ProtocolError.frameTooLarge(payload.count)
        }

        let envelope: Envelope
        do {
            envelope = try makeDecoder().decode(Envelope.self, from: payload)
        } catch {
            throw ProtocolError.malformedEnvelope(Self.describeDecodingFailure(error))
        }

        guard envelope.v == Envelope.currentVersion else {
            throw ProtocolError.unsupportedVersion(envelope.v)
        }
        guard !envelope.type.isEmpty else {
            throw ProtocolError.malformedEnvelope("missing field 'type'")
        }
        guard UUID(uuidString: envelope.id) != nil else {
            throw ProtocolError.malformedEnvelope("invalid field 'id'")
        }
        return envelope
    }

    /// Decodes an envelope from a frame, rejecting non-envelope kinds.
    public static func decode(frame: Frame) throws -> Envelope {
        guard frame.kind == .envelope else { throw ProtocolError.wrongFrameKind }
        return try decode(payload: frame.payload)
    }

    /// Names the offending field without echoing its value.
    private static func describeDecodingFailure(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return "unparseable json"
        }
        switch decodingError {
        case .keyNotFound(let key, _):
            return "missing field '\(key.stringValue)'"
        case .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .dataCorrupted(let context):
            if let field = context.codingPath.last?.stringValue {
                return "invalid field '\(field)'"
            }
            return "unparseable json"
        @unknown default:
            return "unparseable json"
        }
    }
}
