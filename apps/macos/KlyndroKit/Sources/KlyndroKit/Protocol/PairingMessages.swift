import Foundation

/// Body of `pair.request` (protocol §5.4).
public struct PairRequestBody: Sendable, Equatable {
    public var deviceID: DeviceID
    public var deviceName: String
    public var platform: Platform
    public var fingerprint: Fingerprint
    public var nonce: Nonce
    public var protocolVersion: Int
    public var capabilities: [Capability]

    public init(
        deviceID: DeviceID,
        deviceName: String,
        platform: Platform,
        fingerprint: Fingerprint,
        nonce: Nonce,
        protocolVersion: Int = Envelope.currentVersion,
        capabilities: [Capability]
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.fingerprint = fingerprint
        self.nonce = nonce
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

/// Body of `pair.confirm` (protocol §5.4).
public struct PairConfirmBody: Sendable, Equatable {
    public var fingerprint: Fingerprint
    public var nonce: Nonce
    /// SHA-256 of the SAS input, lowercase hex.
    public var sasDigest: Fingerprint

    public init(fingerprint: Fingerprint, nonce: Nonce, sasDigest: Fingerprint) {
        self.fingerprint = fingerprint
        self.nonce = nonce
        self.sasDigest = sasDigest
    }
}

/// Why a pairing attempt failed. Values match the `reason` field in `pair.result`.
public enum PairingFailure: String, Sendable, Equatable, CaseIterable {
    case userRejected = "user_rejected"
    case sasMismatch = "sas_mismatch"
    case windowClosed = "window_closed"
    case rateLimited = "rate_limited"
    case alreadyPaired = "already_paired"
    case internalError = "internal"
}

/// Body of `pair.result` (protocol §5.4).
public struct PairResultBody: Sendable, Equatable {
    public var accepted: Bool
    public var reason: PairingFailure?

    public init(accepted: Bool, reason: PairingFailure? = nil) {
        self.accepted = accepted
        self.reason = reason
    }
}

public enum PairingMessageError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingField(String)
    case invalidField(String)
    case unsupportedProtocolVersion(Int)
    case notAPairingMessage(MessageType)

    public var description: String {
        switch self {
        case .missingField(let name): return "missing field '\(name)'"
        case .invalidField(let name): return "invalid field '\(name)'"
        case .unsupportedProtocolVersion(let version): return "peer speaks protocol version \(version)"
        case .notAPairingMessage(let type): return "\(type.wireName) is not a pairing message"
        }
    }
}

/// Encoding and validation for the three pairing messages.
public enum PairingMessageCodec {
    public static func requestEnvelope(
        _ body: PairRequestBody,
        timestamp: Int64 = Envelope.now()
    ) -> Envelope {
        Envelope(type: .pairRequest, ts: timestamp, body: body.jsonValue)
    }

    public static func confirmEnvelope(
        _ body: PairConfirmBody,
        timestamp: Int64 = Envelope.now()
    ) -> Envelope {
        Envelope(type: .pairConfirm, ts: timestamp, body: body.jsonValue)
    }

    public static func resultEnvelope(
        _ body: PairResultBody,
        timestamp: Int64 = Envelope.now()
    ) -> Envelope {
        Envelope(type: .pairResult, ts: timestamp, body: body.jsonValue)
    }

    public static func decodeRequest(_ envelope: Envelope) throws -> PairRequestBody {
        guard envelope.messageType == .pairRequest else {
            throw PairingMessageError.notAPairingMessage(envelope.messageType)
        }
        guard let body = envelope.body else { throw PairingMessageError.missingField("body") }

        guard let deviceIDHex = body["device_id"]?.stringValue else {
            throw PairingMessageError.missingField("device_id")
        }
        guard let deviceID = DeviceID(hex: deviceIDHex) else {
            throw PairingMessageError.invalidField("device_id")
        }
        guard let name = body["device_name"]?.stringValue, !name.isEmpty,
              name.utf8.count <= HandshakeCodec.maximumDeviceNameBytes else {
            throw PairingMessageError.invalidField("device_name")
        }
        guard let platformRaw = body["platform"]?.stringValue,
              let platform = Platform(rawValue: platformRaw) else {
            throw PairingMessageError.invalidField("platform")
        }
        guard let fingerprintHex = body["fingerprint"]?.stringValue else {
            throw PairingMessageError.missingField("fingerprint")
        }
        guard let fingerprint = Fingerprint(hex: fingerprintHex) else {
            throw PairingMessageError.invalidField("fingerprint")
        }
        guard let nonceHex = body["nonce"]?.stringValue else {
            throw PairingMessageError.missingField("nonce")
        }
        guard let nonce = Nonce(hex: nonceHex) else {
            throw PairingMessageError.invalidField("nonce")
        }
        guard let version = body["protocol_version"]?.intValue else {
            throw PairingMessageError.missingField("protocol_version")
        }
        guard version == Envelope.currentVersion else {
            throw PairingMessageError.unsupportedProtocolVersion(version)
        }
        guard let capabilities = body["capabilities"]?.stringArrayValue else {
            throw PairingMessageError.missingField("capabilities")
        }

        return PairRequestBody(
            deviceID: deviceID,
            deviceName: name,
            platform: platform,
            fingerprint: fingerprint,
            nonce: nonce,
            protocolVersion: version,
            capabilities: Capability.parse(capabilities)
        )
    }

    public static func decodeConfirm(_ envelope: Envelope) throws -> PairConfirmBody {
        guard envelope.messageType == .pairConfirm else {
            throw PairingMessageError.notAPairingMessage(envelope.messageType)
        }
        guard let body = envelope.body else { throw PairingMessageError.missingField("body") }

        guard let fingerprintHex = body["fingerprint"]?.stringValue,
              let fingerprint = Fingerprint(hex: fingerprintHex) else {
            throw PairingMessageError.invalidField("fingerprint")
        }
        guard let nonceHex = body["nonce"]?.stringValue,
              let nonce = Nonce(hex: nonceHex) else {
            throw PairingMessageError.invalidField("nonce")
        }
        guard let digestHex = body["sas_digest"]?.stringValue,
              let digest = Fingerprint(hex: digestHex) else {
            throw PairingMessageError.invalidField("sas_digest")
        }

        return PairConfirmBody(fingerprint: fingerprint, nonce: nonce, sasDigest: digest)
    }

    public static func decodeResult(_ envelope: Envelope) throws -> PairResultBody {
        guard envelope.messageType == .pairResult else {
            throw PairingMessageError.notAPairingMessage(envelope.messageType)
        }
        guard let body = envelope.body else { throw PairingMessageError.missingField("body") }
        guard let accepted = body["accepted"]?.boolValue else {
            throw PairingMessageError.missingField("accepted")
        }
        let reason = body["reason"]?.stringValue.flatMap(PairingFailure.init(rawValue:))
        return PairResultBody(accepted: accepted, reason: reason)
    }
}

// MARK: - JSON

extension PairRequestBody {
    var jsonValue: JSONValue {
        .object([
            "device_id": .string(deviceID.hex),
            "device_name": .string(deviceName),
            "platform": .string(platform.rawValue),
            "fingerprint": .string(fingerprint.hex),
            "nonce": .string(nonce.hex),
            "protocol_version": .number(Double(protocolVersion)),
            "capabilities": .array(capabilities.map { .string($0.rawValue) })
        ])
    }
}

extension PairConfirmBody {
    var jsonValue: JSONValue {
        .object([
            "fingerprint": .string(fingerprint.hex),
            "nonce": .string(nonce.hex),
            "sas_digest": .string(sasDigest.hex)
        ])
    }
}

extension PairResultBody {
    var jsonValue: JSONValue {
        var fields: [String: JSONValue] = ["accepted": .bool(accepted)]
        if let reason {
            fields["reason"] = .string(reason.rawValue)
        }
        return .object(fields)
    }
}
