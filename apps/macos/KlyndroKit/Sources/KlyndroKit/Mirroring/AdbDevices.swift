import Foundation

/// The state `adb` reports for an attached device.
public enum AdbDeviceState: Sendable, Equatable {
    case device
    case unauthorized
    case offline
    case other(String)

    init(_ raw: String) {
        switch raw {
        case "device": self = .device
        case "unauthorized": self = .unauthorized
        case "offline": self = .offline
        default: self = .other(raw)
        }
    }
}

/// How a device is attached. Wireless serials look like `192.168.1.20:5555`.
public enum AdbTransport: Sendable, Equatable {
    case usb
    case wireless
}

/// One row of `adb devices -l`.
public struct AdbDevice: Sendable, Equatable, Identifiable {
    public var serial: String
    public var state: AdbDeviceState
    public var model: String?
    public var transport: AdbTransport

    public var id: String { serial }

    /// True when scrcpy can actually start against this device.
    public var isUsable: Bool { state == .device }

    public init(serial: String, state: AdbDeviceState, model: String?, transport: AdbTransport) {
        self.serial = serial
        self.state = state
        self.model = model
        self.transport = transport
    }

    /// Message for the one state a user can fix themselves in two taps.
    public var actionableProblem: String? {
        switch state {
        case .device:
            return nil
        case .unauthorized:
            return "Accept the USB debugging prompt on the phone, then try again."
        case .offline:
            return "The phone is offline. Reconnect the cable or toggle USB debugging."
        case .other(let raw):
            return "adb reports this device as \"\(raw)\"."
        }
    }
}

/// Parses `adb devices -l`. Pure so every state is testable without a phone.
public enum AdbDevicesParser {
    public static func parse(_ output: String) -> [AdbDevice] {
        output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .compactMap(parseLine)
    }

    private static func parseLine(_ line: String) -> AdbDevice? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Header, daemon chatter ("* daemon started successfully"), and blank lines.
        if trimmed.isEmpty
            || trimmed.hasPrefix("List of devices")
            || trimmed.hasPrefix("*") {
            return nil
        }

        let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2 else { return nil }

        var model: String?
        for field in fields.dropFirst(2) where field.hasPrefix("model:") {
            model = String(field.dropFirst("model:".count))
        }

        let serial = fields[0]
        return AdbDevice(
            serial: serial,
            state: AdbDeviceState(fields[1]),
            model: model,
            transport: serial.contains(":") ? .wireless : .usb
        )
    }
}
