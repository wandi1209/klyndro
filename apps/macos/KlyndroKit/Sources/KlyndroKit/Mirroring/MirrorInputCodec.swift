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
