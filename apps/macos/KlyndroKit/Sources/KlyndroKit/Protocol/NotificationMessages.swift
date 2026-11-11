import Foundation

/// Body of a `notification.post` envelope (protocol §5.3).
public struct NotificationPostBody: Sendable, Equatable, Codable {
    /// Composite key: "<package>:<id>:<postTime>". Used for deduplication.
    public var key: String
    /// Android package name, e.g. "org.telegram.messenger".
    public var package: String
    /// Human-readable application name, e.g. "Telegram".
    public var appName: String
    public var title: String
    public var text: String
    /// Epoch millis when the notification was posted on the originating device.
    public var postedAt: Int64
    /// Whether the originating device considered this notification sensitive.
    public var sensitive: Bool

    enum CodingKeys: String, CodingKey {
        case key
        case package
        case appName = "app_name"
        case title
        case text
        case postedAt = "posted_at"
        case sensitive
    }

    public init(
        key: String,
        package: String,
        appName: String,
        title: String,
        text: String,
        postedAt: Int64,
        sensitive: Bool = false
    ) {
        self.key = key
        self.package = package
        self.appName = appName
        self.title = title
        self.text = text
        self.postedAt = postedAt
        self.sensitive = sensitive
    }
}

public enum NotificationMessageError: Error, Equatable, Sendable, CustomStringConvertible {
    case notANotificationMessage(MessageType)
    case missingField(String)
    case invalidField(String)
    case payloadTooLarge(String, Int, Int)

    public var description: String {
        switch self {
        case .notANotificationMessage(let type): return "\(type.wireName) is not a notification message"
        case .missingField(let name): return "missing field '\(name)'"
        case .invalidField(let name): return "invalid field '\(name)'"
        case .payloadTooLarge(let field, let bytes, let limit): return "\(field) is \(bytes) bytes (limit \(limit))"
        }
    }
}

/// Enforces size limits and wire encoding for `notification.post`.
public enum NotificationMessageCodec {
    public static let maxTitleBytes = 1024
    public static let maxTextBytes = 8192
    public static let maxPackageBytes = 256
    public static let maxKeyBytes = 512

    public static func postEnvelope(_ body: NotificationPostBody) throws -> Envelope {
        guard body.title.utf8.count <= maxTitleBytes else {
            throw NotificationMessageError.payloadTooLarge("title", body.title.utf8.count, maxTitleBytes)
        }
        guard body.text.utf8.count <= maxTextBytes else {
            throw NotificationMessageError.payloadTooLarge("text", body.text.utf8.count, maxTextBytes)
        }
        guard body.package.utf8.count <= maxPackageBytes else {
            throw NotificationMessageError.payloadTooLarge("package", body.package.utf8.count, maxPackageBytes)
        }

        let obj: [String: JSONValue] = [
            "key": .string(body.key),
            "package": .string(body.package),
            "app_name": .string(body.appName),
            "title": .string(body.title),
            "text": .string(body.text),
            "posted_at": .number(Double(body.postedAt)),
            "sensitive": .bool(body.sensitive)
        ]

        return Envelope(
            type: .notificationPost,
            body: .object(obj)
        )
    }

    public static func decodePost(_ envelope: Envelope) throws -> NotificationPostBody {
        guard envelope.messageType == .notificationPost else {
            throw NotificationMessageError.notANotificationMessage(envelope.messageType)
        }
        guard let body = envelope.body else {
            throw NotificationMessageError.missingField("body")
        }

        guard let key = body["key"]?.stringValue else {
            throw NotificationMessageError.missingField("key")
        }
        guard let package = body["package"]?.stringValue else {
            throw NotificationMessageError.missingField("package")
        }
        guard let appName = body["app_name"]?.stringValue else {
            throw NotificationMessageError.missingField("app_name")
        }
        let title = body["title"]?.stringValue ?? ""
        let text = body["text"]?.stringValue ?? ""
        let postedAtDouble = body["posted_at"]?.intValue.map(Double.init)
            ?? {
                if case .number(let n) = body["posted_at"] { return n }
                return Double(Date().timeIntervalSince1970 * 1000)
            }()
        let sensitive = body["sensitive"]?.boolValue ?? false

        return NotificationPostBody(
            key: key,
            package: package,
            appName: appName,
            title: title,
            text: text,
            postedAt: Int64(postedAtDouble),
            sensitive: sensitive
        )
    }
}
