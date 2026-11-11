import Foundation
import X509

/// Decides whether a peer certificate may be trusted.
///
/// This is the single place where a TLS peer becomes "known". It is a pure function of the
/// presented certificate and the current policy, which makes the accept/reject matrix
/// testable without a socket.
public struct PinPolicy: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// Only these fingerprints are accepted. Used for every normal session.
        case pinned(Set<Fingerprint>)
        /// Accept any certificate. Only ever used while a pairing window is open, and the
        /// resulting session may do nothing except pair.
        case pairingWindow
    }

    public let mode: Mode

    public init(mode: Mode) {
        self.mode = mode
    }

    public static let pairingOnly = PinPolicy(mode: .pairingWindow)

    public static func pinned(_ fingerprints: Set<Fingerprint>) -> PinPolicy {
        PinPolicy(mode: .pinned(fingerprints))
    }

    public static func pinned(_ peers: [TrustedPeer]) -> PinPolicy {
        PinPolicy(mode: .pinned(Set(peers.compactMap(\.fingerprintValue))))
    }

    /// Evaluates a DER-encoded certificate.
    public func evaluate(peerCertificateDER: Data) -> PinDecision {
        let fingerprint: Fingerprint
        do {
            fingerprint = try DeviceIdentityStore.fingerprint(ofCertificateDER: peerCertificateDER)
        } catch {
            return .rejected(.unparsableCertificate)
        }

        switch mode {
        case .pairingWindow:
            return .accepted(fingerprint, isPinned: false)
        case .pinned(let allowed):
            guard !allowed.isEmpty else { return .rejected(.noPairedPeers) }
            guard allowed.contains(fingerprint) else {
                return .rejected(.fingerprintNotTrusted(fingerprint))
            }
            return .accepted(fingerprint, isPinned: true)
        }
    }
}

public enum PinDecision: Sendable, Equatable {
    case accepted(Fingerprint, isPinned: Bool)
    case rejected(PinRejection)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    public var fingerprint: Fingerprint? {
        if case .accepted(let fingerprint, _) = self { return fingerprint }
        return nil
    }
}

public enum PinRejection: Error, Equatable, Sendable, CustomStringConvertible {
    case unparsableCertificate
    case noPairedPeers
    case fingerprintNotTrusted(Fingerprint)

    public var description: String {
        switch self {
        case .unparsableCertificate:
            return "peer presented an unreadable certificate"
        case .noPairedPeers:
            return "no paired devices are trusted yet"
        case .fingerprintNotTrusted(let fingerprint):
            return "peer certificate is not trusted (\(fingerprint.shortHex))"
        }
    }
}
