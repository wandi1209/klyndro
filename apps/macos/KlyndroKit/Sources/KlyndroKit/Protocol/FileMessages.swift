import Foundation

public struct FileOfferBody: Sendable, Equatable, Codable {
    public var transferId: String
    public var filename: String
    public var sizeBytes: Int64
    public var sha256: String
    public var mimeType: String

    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case filename
        case sizeBytes = "size_bytes"
        case sha256
        case mimeType = "mime_type"
    }

    public init(transferId: String, filename: String, sizeBytes: Int64, sha256: String, mimeType: String = "application/octet-stream") {
        self.transferId = transferId
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.mimeType = mimeType
    }
}

public struct FileAcceptBody: Sendable, Equatable, Codable {
    public var transferId: String
    enum CodingKeys: String, CodingKey { case transferId = "transfer_id" }
    public init(transferId: String) { self.transferId = transferId }
}

public struct FileRejectBody: Sendable, Equatable, Codable {
    public var transferId: String
    public var reason: String
    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case reason
    }
    public init(transferId: String, reason: String) {
        self.transferId = transferId
        self.reason = reason
    }
}

public struct FileChunkBody: Sendable, Equatable, Codable {
    public var transferId: String
    public var offset: Int64
    public var dataB64: String
    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case offset
        case dataB64 = "data_b64"
    }
    public init(transferId: String, offset: Int64, dataB64: String) {
        self.transferId = transferId
        self.offset = offset
        self.dataB64 = dataB64
    }
}

public struct FileCompleteBody: Sendable, Equatable, Codable {
    public var transferId: String
    public var sha256: String
    enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case sha256
    }
    public init(transferId: String, sha256: String) {
        self.transferId = transferId
        self.sha256 = sha256
    }
}

public enum FileMessageError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAFileMessage(MessageType)
    case missingField(String)
    case invalidField(String)
    case payloadTooLarge(Int)

    public var description: String {
        switch self {
        case .notAFileMessage(let type): return "\(type.wireName) is not a file message"
        case .missingField(let name): return "missing field '\(name)'"
        case .invalidField(let name): return "invalid field '\(name)'"
        case .payloadTooLarge(let bytes): return "chunk payload too large (\(bytes) bytes)"
        }
    }
}

public enum FileMessageCodec {
    public static let maxChunkRawBytes = 512 * 1024 // 512 KiB

    public static func offerEnvelope(_ body: FileOfferBody) -> Envelope {
        let obj: [String: JSONValue] = [
            "transfer_id": .string(body.transferId),
            "filename": .string(sanitizeFilename(body.filename)),
            "size_bytes": .number(Double(body.sizeBytes)),
            "sha256": .string(body.sha256.lowercased()),
            "mime_type": .string(body.mimeType)
        ]
        return Envelope(type: .fileOffer, body: .object(obj))
    }

    public static func decodeOffer(_ envelope: Envelope) throws -> FileOfferBody {
        guard envelope.messageType == .fileOffer else {
            throw FileMessageError.notAFileMessage(envelope.messageType)
        }
        guard let body = envelope.body else { throw FileMessageError.missingField("body") }
        guard let transferId = body["transfer_id"]?.stringValue else { throw FileMessageError.missingField("transfer_id") }
        guard let filename = body["filename"]?.stringValue else { throw FileMessageError.missingField("filename") }
        guard let size = body["size_bytes"]?.intValue else { throw FileMessageError.missingField("size_bytes") }
        guard let sha = body["sha256"]?.stringValue else { throw FileMessageError.missingField("sha256") }
        let mime = body["mime_type"]?.stringValue ?? "application/octet-stream"

        return FileOfferBody(
            transferId: transferId,
            filename: sanitizeFilename(filename),
            sizeBytes: Int64(size),
            sha256: sha.lowercased(),
            mimeType: mime
        )
    }

    public static func sanitizeFilename(_ name: String) -> String {
        let base = URL(fileURLWithPath: name).lastPathComponent
        let sanitized = base.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        return sanitized.isEmpty ? "unnamed_file" : String(sanitized.prefix(255))
    }
}
