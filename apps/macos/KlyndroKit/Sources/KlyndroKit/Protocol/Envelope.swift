import Foundation

/// Message types known to this implementation. Anything else decodes as `.unknown`,
/// which is *valid*: §5 requires unknown types to be ignored, not rejected.
public enum MessageType: Equatable, Sendable, Hashable {
    case hello
    case helloAck
    case ping
    case pong
    case clipboardUpdate
    case clipboardAck
    case notificationPost
    case pairRequest
    case pairConfirm
    case pairResult
    case error
    case unknown(String)

    public init(wireName: String) {
        switch wireName {
        case "hello": self = .hello
        case "hello.ack": self = .helloAck
        case "ping": self = .ping
        case "pong": self = .pong
        case "clipboard.update": self = .clipboardUpdate
        case "clipboard.ack": self = .clipboardAck
        case "notification.post": self = .notificationPost
        case "pair.request": self = .pairRequest
        case "pair.confirm": self = .pairConfirm
        case "pair.result": self = .pairResult
        case "error": self = .error
        default: self = .unknown(wireName)
        }
    }

    public var wireName: String {
        switch self {
        case .hello: return "hello"
        case .helloAck: return "hello.ack"
        case .ping: return "ping"
        case .pong: return "pong"
        case .clipboardUpdate: return "clipboard.update"
        case .clipboardAck: return "clipboard.ack"
        case .notificationPost: return "notification.post"
        case .pairRequest: return "pair.request"
        case .pairConfirm: return "pair.confirm"
        case .pairResult: return "pair.result"
        case .error: return "error"
        case .unknown(let name): return name
        }
    }

    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

/// Envelope, Klyndro Protocol v1 §4.
public struct Envelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var v: Int
    /// UUID string, unique per message per sender.
    public var id: String
    public var type: String
    /// Sender wall clock in milliseconds since the Unix epoch. Informational only.
    public var ts: Int64
    public var body: JSONValue?

    public init(
        v: Int = Envelope.currentVersion,
        id: String = UUID().uuidString.lowercased(),
        type: MessageType,
        ts: Int64 = Envelope.now(),
        body: JSONValue? = nil
    ) {
        self.v = v
        self.id = id
        self.type = type.wireName
        self.ts = ts
        self.body = body
    }

    /// Raw initialiser for decoding and for tests that need an arbitrary type string.
    public init(v: Int, id: String, type: String, ts: Int64, body: JSONValue?) {
        self.v = v
        self.id = id
        self.type = type
        self.ts = ts
        self.body = body
    }

    public var messageType: MessageType { MessageType(wireName: type) }

    public func bodyField(_ key: String) -> JSONValue? { body?[key] }

    enum CodingKeys: String, CodingKey {
        case v, id, type, ts, body
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        ts = try container.decode(Int64.self, forKey: .ts)
        body = try container.decodeIfPresent(JSONValue.self, forKey: .body)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(ts, forKey: .ts)
        // §4: an absent body is omitted, never encoded as null.
        if let body, body != .null {
            try container.encode(body, forKey: .body)
        }
    }

    public static func now() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
