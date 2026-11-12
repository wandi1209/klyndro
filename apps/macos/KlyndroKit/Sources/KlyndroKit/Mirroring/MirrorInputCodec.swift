import Foundation

public enum InputGestureKind: String, Equatable, Sendable {
    case tap
    case longPress = "long_press"
    case swipe
}

public struct InputGestureBody: Equatable, Sendable {
    public static let durationRange = 1...5000

    public var kind: InputGestureKind
    public var x: Double
    public var y: Double
    public var endX: Double?
    public var endY: Double?
    public var durationMs: Int

    public init(
        kind: InputGestureKind,
        x: Double,
        y: Double,
        endX: Double? = nil,
        endY: Double? = nil,
        durationMs: Int? = nil
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.endX = endX
        self.endY = endY
        self.durationMs = durationMs ?? {
            switch kind {
            case .tap: return 50
            case .longPress: return 600
            case .swipe: return 220
            }
        }()
    }

    public func toEnvelope() -> Envelope {
        var fields: [String: JSONValue] = [
            "kind": .string(kind.rawValue),
            "x": .number(x),
            "y": .number(y),
            "duration_ms": .number(Double(durationMs))
        ]
        if let endX, let endY {
            fields["end_x"] = .number(endX)
            fields["end_y"] = .number(endY)
        }
        return Envelope(type: .inputGesture, body: .object(fields))
    }

    public static func decode(_ envelope: Envelope) -> InputGestureBody? {
        guard envelope.messageType == .inputGesture,
              let body = envelope.body,
              let kindRaw = body["kind"]?.stringValue,
              let kind = InputGestureKind(rawValue: kindRaw),
              let x = number(body["x"]), (0.0...1.0).contains(x),
              let y = number(body["y"]), (0.0...1.0).contains(y),
              let duration = body["duration_ms"]?.intValue, durationRange.contains(duration) else {
            return nil
        }

        if kind == .swipe {
            guard let endX = number(body["end_x"]), (0.0...1.0).contains(endX),
                  let endY = number(body["end_y"]), (0.0...1.0).contains(endY) else {
                return nil
            }
            return InputGestureBody(kind: kind, x: x, y: y, endX: endX, endY: endY, durationMs: duration)
        }
        return InputGestureBody(kind: kind, x: x, y: y, durationMs: duration)
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case .number(let number)? = value, number.isFinite else { return nil }
        return number
    }
}

public enum InputActionKind: String, Equatable, Sendable {
    case back
    case home
    case recents
    case notifications
    case lockScreen = "lock_screen"
}

public struct InputActionBody: Equatable, Sendable {
    public var action: InputActionKind

    public init(action: InputActionKind) {
        self.action = action
    }

    public func toEnvelope() -> Envelope {
        Envelope(type: .inputAction, body: .object(["action": .string(action.rawValue)]))
    }

    public static func decode(_ envelope: Envelope) -> InputActionBody? {
        guard envelope.messageType == .inputAction,
              let body = envelope.body,
              let raw = body["action"]?.stringValue,
              let action = InputActionKind(rawValue: raw) else {
            return nil
        }
        return InputActionBody(action: action)
    }
}

public enum InputTextMode: String, Equatable, Sendable {
    case append
    case replace
    case backspace
}

public struct InputTextBody: Equatable, Sendable {
    public static let maxUTF8Bytes = 4096

    public var mode: InputTextMode
    public var text: String

    public init(mode: InputTextMode = .append, text: String = "") {
        self.mode = mode
        self.text = text
    }

    public func toEnvelope() -> Envelope {
        Envelope(
            type: .inputText,
            body: .object([
                "mode": .string(mode.rawValue),
                "text": .string(text)
            ])
        )
    }

    public static func decode(_ envelope: Envelope) -> InputTextBody? {
        guard envelope.messageType == .inputText,
              let body = envelope.body,
              let modeRaw = body["mode"]?.stringValue,
              let mode = InputTextMode(rawValue: modeRaw),
              let text = body["text"]?.stringValue,
              text.utf8.count <= maxUTF8Bytes else {
            return nil
        }
        if mode != .backspace && text.isEmpty {
            return nil
        }
        return InputTextBody(mode: mode, text: text)
    }
}

public struct StandardAppEntry: Equatable, Hashable, Sendable {
    public var package: AdbPackageName
    public var label: String

    public init?(package: String, label: String) {
        guard let validated = AdbPackageName(package) else { return nil }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else { return nil }
        self.package = validated
        self.label = String(trimmedLabel.prefix(128))
    }
}

public enum AppLauncherMessages {
    public static let maxApps = 500

    public static func listRequestEnvelope() -> Envelope {
        Envelope(type: .appListRequest)
    }

    public static func launchEnvelope(package: AdbPackageName) -> Envelope {
        Envelope(type: .appLaunch, body: .object(["package": .string(package.value)]))
    }

    public static func listEnvelope(apps: [StandardAppEntry]) -> Envelope {
        let items: [JSONValue] = apps.prefix(maxApps).map { entry in
            .object([
                "package": .string(entry.package.value),
                "label": .string(entry.label)
            ])
        }
        return Envelope(type: .appList, body: .object(["apps": .array(items)]))
    }

    public static func decodeList(_ envelope: Envelope) -> [StandardAppEntry]? {
        guard envelope.messageType == .appList,
              let body = envelope.body,
              case .array(let items)? = body["apps"] else {
            return nil
        }
        var result: [StandardAppEntry] = []
        var seen = Set<String>()
        for item in items.prefix(maxApps) {
            guard let pkg = item["package"]?.stringValue,
                  let label = item["label"]?.stringValue,
                  let entry = StandardAppEntry(package: pkg, label: label),
                  seen.insert(entry.package.value).inserted else {
                continue
            }
            result.append(entry)
        }
        return result.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    public static func decodeLaunch(_ envelope: Envelope) -> AdbPackageName? {
        guard envelope.messageType == .appLaunch,
              let body = envelope.body,
              let pkg = body["package"]?.stringValue else {
            return nil
        }
        return AdbPackageName(pkg)
    }
}
