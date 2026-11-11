import CryptoKit
import Foundation

/// Clipboard content type. v1 carries UTF-8 text only (protocol §5.2).
public enum ClipboardContentType: String, Sendable, Codable, CaseIterable {
    case plainText = "text/plain"
}

/// Body of `clipboard.update` (protocol §5.2).
public struct ClipboardUpdateBody: Sendable, Equatable {
    public var contentType: ClipboardContentType
    public var text: String
    /// Lowercase hex SHA-256 of the UTF-8 text. Loop and duplicate suppression depends on it.
    public var hash: String
    /// Sender's monotonic counter, used to reject stale updates after a reconnect.
    public var changeCount: Int
    /// Device that first produced this content.
    public var originID: DeviceID
    public var sensitive: Bool

    public init(
        contentType: ClipboardContentType = .plainText,
        text: String,
        hash: String,
        changeCount: Int,
        originID: DeviceID,
        sensitive: Bool
    ) {
        self.contentType = contentType
        self.text = text
        self.hash = hash
        self.changeCount = changeCount
        self.originID = originID
        self.sensitive = sensitive
    }
}

/// Why a receiver refused clipboard content (protocol §5.2).
public enum ClipboardRejectReason: String, Sendable, Equatable, CaseIterable {
    case tooLarge = "too_large"
    case unsupportedType = "unsupported_type"
    case disabled = "disabled"
    case sensitive = "sensitive"
}

/// Body of `clipboard.ack` (protocol §5.2).
public struct ClipboardAckBody: Sendable, Equatable {
    public var refID: String
    public var accepted: Bool
    public var reason: ClipboardRejectReason?

    public init(refID: String, accepted: Bool, reason: ClipboardRejectReason? = nil) {
        self.refID = refID
        self.accepted = accepted
        self.reason = reason
    }
}

public enum ClipboardMessageError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAClipboardMessage(MessageType)
    case missingField(String)
    case invalidField(String)
    case payloadTooLarge(Int)

    public var description: String {
        switch self {
        case .notAClipboardMessage(let type): return "\(type.wireName) is not a clipboard message"
        case .missingField(let name): return "missing field '\(name)'"
        case .invalidField(let name): return "invalid field '\(name)'"
        case .payloadTooLarge(let bytes): return "clipboard payload is \(bytes) bytes"
        }
    }
}

/// Encoding and validation for clipboard messages.
public enum ClipboardMessageCodec {
    /// Protocol §5.2 / §10: 256 KiB of UTF-8.
    public static let maximumTextBytes = 262_144

    public static func updateEnvelope(
        _ body: ClipboardUpdateBody,
        timestamp: Int64 = Envelope.now()
    ) -> Envelope {
        Envelope(type: .clipboardUpdate, ts: timestamp, body: body.jsonValue)
    }

    public static func ackEnvelope(
        _ body: ClipboardAckBody,
        timestamp: Int64 = Envelope.now()
    ) -> Envelope {
        Envelope(type: .clipboardAck, ts: timestamp, body: body.jsonValue)
    }

    public static func decodeUpdate(_ envelope: Envelope) throws -> ClipboardUpdateBody {
        guard envelope.messageType == .clipboardUpdate else {
            throw ClipboardMessageError.notAClipboardMessage(envelope.messageType)
        }
        guard let body = envelope.body else { throw ClipboardMessageError.missingField("body") }

        guard let contentTypeRaw = body["content_type"]?.stringValue else {
            throw ClipboardMessageError.missingField("content_type")
        }
        guard let contentType = ClipboardContentType(rawValue: contentTypeRaw) else {
            throw ClipboardMessageError.invalidField("content_type")
        }
        guard let text = body["text"]?.stringValue else {
            throw ClipboardMessageError.missingField("text")
        }
        // Check the byte cost, not the character count: a 256 KiB limit is about bytes on the
        // wire, and emoji or CJK text would otherwise slip past.
        let byteCount = text.utf8.count
        guard byteCount <= maximumTextBytes else {
            throw ClipboardMessageError.payloadTooLarge(byteCount)
        }
        guard let hash = body["hash"]?.stringValue, Fingerprint.isValidHex(hash) else {
            throw ClipboardMessageError.invalidField("hash")
        }
        guard let changeCount = body["change_count"]?.intValue, changeCount >= 0 else {
            throw ClipboardMessageError.invalidField("change_count")
        }
        guard let originHex = body["origin_id"]?.stringValue,
              let origin = DeviceID(hex: originHex) else {
            throw ClipboardMessageError.invalidField("origin_id")
        }

        return ClipboardUpdateBody(
            contentType: contentType,
            text: text,
            hash: hash.lowercased(),
            changeCount: changeCount,
            originID: origin,
            sensitive: body["sensitive"]?.boolValue ?? false
        )
    }

    public static func decodeAck(_ envelope: Envelope) throws -> ClipboardAckBody {
        guard envelope.messageType == .clipboardAck else {
            throw ClipboardMessageError.notAClipboardMessage(envelope.messageType)
        }
        guard let body = envelope.body else { throw ClipboardMessageError.missingField("body") }
        guard let refID = body["ref_id"]?.stringValue else {
            throw ClipboardMessageError.missingField("ref_id")
        }
        guard let accepted = body["accepted"]?.boolValue else {
            throw ClipboardMessageError.missingField("accepted")
        }
        let reason = body["reason"]?.stringValue.flatMap(ClipboardRejectReason.init(rawValue:))
        return ClipboardAckBody(refID: refID, accepted: accepted, reason: reason)
    }

    /// SHA-256 of the UTF-8 text, lowercase hex. Shared shape with the Kotlin implementation.
    public static func hash(of text: String) -> String {
        Fingerprint.hexString(Array(SHA256.hash(data: Data(text.utf8))))
    }
}

extension ClipboardUpdateBody {
    var jsonValue: JSONValue {
        .object([
            "content_type": .string(contentType.rawValue),
            "text": .string(text),
            "hash": .string(hash),
            "change_count": .number(Double(changeCount)),
            "origin_id": .string(originID.hex),
            "sensitive": .bool(sensitive)
        ])
    }
}

extension ClipboardAckBody {
    var jsonValue: JSONValue {
        var fields: [String: JSONValue] = [
            "ref_id": .string(refID),
            "accepted": .bool(accepted)
        ]
        if let reason {
            fields["reason"] = .string(reason.rawValue)
        }
        return .object(fields)
    }
}
