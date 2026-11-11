import Foundation

/// Body of `hello` (protocol §5.1).
public struct HelloBody: Sendable, Equatable {
    public var deviceID: DeviceID
    public var deviceName: String
    public var platform: Platform
    public var appVersion: String
    public var protocolVersion: Int
    public var capabilities: [Capability]
    public var nonce: Nonce

    public init(
        deviceID: DeviceID,
        deviceName: String,
        platform: Platform,
        appVersion: String,
        protocolVersion: Int = Envelope.currentVersion,
        capabilities: [Capability],
        nonce: Nonce
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.nonce = nonce
    }
}

/// Body of `hello.ack`: the same fields plus an echo of the peer's nonce.
public struct HelloAckBody: Sendable, Equatable {
    public var hello: HelloBody
    public var echoNonce: Nonce

    public init(hello: HelloBody, echoNonce: Nonce) {
        self.hello = hello
        self.echoNonce = echoNonce
    }
}

public enum HandshakeError: Error, Equatable, Sendable, CustomStringConvertible {
    case wrongMessageType(expected: MessageType, actual: MessageType)
    case unsupportedProtocolVersion(Int)
    case missingField(String)
    case invalidField(String)
    case nonceEchoMismatch

    public var description: String {
        switch self {
        case .wrongMessageType(let expected, let actual):
            return "expected \(expected.wireName), received \(actual.wireName)"
        case .unsupportedProtocolVersion(let version):
            return "peer speaks protocol version \(version)"
        case .missingField(let name):
            return "missing field '\(name)'"
        case .invalidField(let name):
            return "invalid field '\(name)'"
        case .nonceEchoMismatch:
            return "nonce echo did not match; possible replay"
        }
    }
}

/// Encoding and validation for the session handshake.
///
/// Kept separate from the transport so both platforms can share the exact rules and so the
/// rules are testable without sockets.
public enum HandshakeCodec {
    public static let maximumDeviceNameBytes = 256
    public static let maximumAppVersionBytes = 64

    public static func helloEnvelope(_ body: HelloBody, timestamp: Int64 = Envelope.now()) -> Envelope {
        Envelope(type: .hello, ts: timestamp, body: body.jsonValue)
    }

    public static func helloAckEnvelope(_ body: HelloAckBody, timestamp: Int64 = Envelope.now()) -> Envelope {
        Envelope(type: .helloAck, ts: timestamp, body: body.jsonValue)
    }

    public static func decodeHello(_ envelope: Envelope) throws -> HelloBody {
        guard envelope.messageType == .hello else {
            throw HandshakeError.wrongMessageType(expected: .hello, actual: envelope.messageType)
        }
        return try parseHelloBody(envelope.body)
    }

    public static func decodeHelloAck(_ envelope: Envelope) throws -> HelloAckBody {
        guard envelope.messageType == .helloAck else {
            throw HandshakeError.wrongMessageType(expected: .helloAck, actual: envelope.messageType)
        }
        let hello = try parseHelloBody(envelope.body)
        guard let echo = envelope.bodyField("echo_nonce")?.stringValue else {
            throw HandshakeError.missingField("echo_nonce")
        }
        guard let nonce = Nonce(hex: echo) else {
            throw HandshakeError.invalidField("echo_nonce")
        }
        return HelloAckBody(hello: hello, echoNonce: nonce)
    }

    /// Verifies the ack belongs to *this* connection, which blocks replayed hellos.
    public static func verify(ack: HelloAckBody, expectedEcho: Nonce) throws {
        guard ack.echoNonce.hex == expectedEcho.hex else {
            throw HandshakeError.nonceEchoMismatch
        }
    }

    /// Shared field validation. Order matches the Swift/Kotlin implementations and protocol §4.
    static func parseHelloBody(_ body: JSONValue?) throws -> HelloBody {
        guard let body else { throw HandshakeError.missingField("body") }

        guard let deviceIDHex = body["device_id"]?.stringValue else {
            throw HandshakeError.missingField("device_id")
        }
        guard let deviceID = DeviceID(hex: deviceIDHex) else {
            throw HandshakeError.invalidField("device_id")
        }

        guard let name = body["device_name"]?.stringValue else {
            throw HandshakeError.missingField("device_name")
        }
        guard !name.isEmpty, name.utf8.count <= maximumDeviceNameBytes else {
            throw HandshakeError.invalidField("device_name")
        }

        guard let platformRaw = body["platform"]?.stringValue,
              let platform = Platform(rawValue: platformRaw) else {
            throw HandshakeError.invalidField("platform")
        }

        guard let appVersion = body["app_version"]?.stringValue else {
            throw HandshakeError.missingField("app_version")
        }
        guard appVersion.utf8.count <= maximumAppVersionBytes else {
            throw HandshakeError.invalidField("app_version")
        }

        guard let protocolVersion = body["protocol_version"]?.intValue else {
            throw HandshakeError.missingField("protocol_version")
        }
        guard protocolVersion == Envelope.currentVersion else {
            throw HandshakeError.unsupportedProtocolVersion(protocolVersion)
        }

        guard let capabilities = body["capabilities"]?.stringArrayValue else {
            throw HandshakeError.missingField("capabilities")
        }

        guard let nonceHex = body["nonce"]?.stringValue else {
            throw HandshakeError.missingField("nonce")
        }
        guard let nonce = Nonce(hex: nonceHex) else {
            throw HandshakeError.invalidField("nonce")
        }

        return HelloBody(
            deviceID: deviceID,
            deviceName: name,
            platform: platform,
            appVersion: appVersion,
            protocolVersion: protocolVersion,
            capabilities: Capability.parse(capabilities),
            nonce: nonce
        )
    }
}

// MARK: - JSON

extension HelloBody {
    var jsonValue: JSONValue {
        .object([
            "device_id": .string(deviceID.hex),
            "device_name": .string(deviceName),
            "platform": .string(platform.rawValue),
            "app_version": .string(appVersion),
            "protocol_version": .number(Double(protocolVersion)),
            "capabilities": .array(capabilities.map { .string($0.rawValue) }),
            "nonce": .string(nonce.hex)
        ])
    }
}

extension HelloAckBody {
    var jsonValue: JSONValue {
        guard case .object(var fields) = hello.jsonValue else { return hello.jsonValue }
        fields["echo_nonce"] = .string(echoNonce.hex)
        return .object(fields)
    }
}
