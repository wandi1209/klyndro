import Foundation

/// A timed pairing window (protocol §7).
///
/// The window is the only period during which an *unpinned* TLS peer is allowed to complete a
/// handshake, so its bounds are security-relevant and therefore unit-tested.
public struct PairingWindow: Sendable, Equatable {
    public static let defaultDuration: TimeInterval = 60
    public static let defaultMaxAttempts = 3

    public let openedAt: Date
    public let duration: TimeInterval
    public let maxAttempts: Int
    public private(set) var attempts: Int

    public init(
        openedAt: Date = Date(),
        duration: TimeInterval = PairingWindow.defaultDuration,
        maxAttempts: Int = PairingWindow.defaultMaxAttempts
    ) {
        self.openedAt = openedAt
        self.duration = duration
        self.maxAttempts = maxAttempts
        self.attempts = 0
    }

    public func isOpen(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(openedAt) >= 0 && now.timeIntervalSince(openedAt) < duration
    }

    public func remaining(at now: Date = Date()) -> TimeInterval {
        max(0, duration - now.timeIntervalSince(openedAt))
    }

    /// Counts an attempt or refuses it. Refusal happens *before* any TLS work is accepted.
    public mutating func beginAttempt(at now: Date = Date()) throws {
        guard isOpen(at: now) else { throw PairingWindowError.windowClosed }
        guard attempts < maxAttempts else { throw PairingWindowError.rateLimited }
        attempts += 1
    }
}

public enum PairingWindowError: Error, Equatable, Sendable, CustomStringConvertible {
    case windowClosed
    case rateLimited

    public var description: String {
        switch self {
        case .windowClosed: return "the pairing window is closed"
        case .rateLimited: return "too many pairing attempts"
        }
    }
}

/// One in-flight pairing attempt: enough state to display a code and verify the peer's
/// confirmation, with no I/O.
public struct PairingAttempt: Sendable, Equatable {
    public let remote: PairRequestBody
    public let localFingerprint: Fingerprint
    public let localNonce: Nonce
    /// The six digits both users must see.
    public let code: PairingCode

    public init(remote: PairRequestBody, localFingerprint: Fingerprint, localNonce: Nonce) {
        self.remote = remote
        self.localFingerprint = localFingerprint
        self.localNonce = localNonce
        self.code = PairingCode(
            peerA: (localFingerprint, localNonce),
            peerB: (remote.fingerprint, remote.nonce)
        )
    }

    public var remoteDeviceID: DeviceID { remote.deviceID }
    public var remoteFingerprint: Fingerprint { remote.fingerprint }

    /// The confirmation we send once the user agrees the digits match.
    public func confirmBody() -> PairConfirmBody {
        PairConfirmBody(
            fingerprint: localFingerprint,
            nonce: localNonce,
            sasDigest: code.digest
        )
    }

    /// Verifies the peer's confirmation. Fingerprint and nonce are checked first: a peer that
    /// echoes different values cannot have hashed the same input, regardless of the digits.
    public func validate(_ confirm: PairConfirmBody) throws {
        guard confirm.fingerprint.matches(remote.fingerprint) else {
            throw PairingValidationError.fingerprintMismatch
        }
        guard confirm.nonce.hex == remote.nonce.hex else {
            throw PairingValidationError.nonceMismatch
        }
        guard confirm.sasDigest.matches(code.digest) else {
            throw PairingValidationError.digestMismatch
        }
    }

    /// Builds the trust record to persist after a successful pairing.
    public func trustedPeer(host: String?, port: Int?, at date: Date = Date()) -> TrustedPeer {
        TrustedPeer(
            deviceID: remote.deviceID.hex,
            name: remote.deviceName,
            platform: remote.platform.rawValue,
            fingerprint: remote.fingerprint.hex,
            lastHost: host,
            lastPort: port,
            pairedAt: date
        )
    }
}

public enum PairingValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case fingerprintMismatch
    case nonceMismatch
    case digestMismatch

    public var description: String {
        switch self {
        case .fingerprintMismatch: return "peer confirmed a different fingerprint"
        case .nonceMismatch: return "peer confirmed a different nonce"
        case .digestMismatch: return "peer computed a different pairing code"
        }
    }
}
