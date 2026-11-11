import CryptoKit
import Foundation

/// A per-connection 16-byte random value, hex encoded (protocol §4/§5.1).
public struct Nonce: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 16
    public static let hexLength = 32

    public let hex: String

    public init?(hex: String) {
        guard hex.count == Self.hexLength, hex.allSatisfy(\.isHexDigit) else { return nil }
        self.hex = hex.lowercased()
    }

    public init() {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.byteCount)
        for _ in 0..<Self.byteCount {
            bytes.append(UInt8.random(in: .min ... .max, using: &generator))
        }
        self.hex = Fingerprint.hexString(bytes)
    }

    public var description: String { hex }
}

/// The six-digit short authentication string shown on both devices during pairing (§7).
public struct PairingCode: Hashable, Sendable, CustomStringConvertible {
    /// Human-visible digits, zero padded to six places.
    public let digits: String
    /// Full SHA-256 of the SAS input, hex. Sent in `pair.confirm` and compared exactly.
    public let digest: Fingerprint

    public var description: String { digits }

    /// Derives the code deterministically from both peers' fingerprints and nonces.
    ///
    /// Ordering is by fingerprint so that both devices hash identical bytes regardless of
    /// who initiated. See protocol §7 step 4.
    public init(peerA: (fingerprint: Fingerprint, nonce: Nonce),
                peerB: (fingerprint: Fingerprint, nonce: Nonce)) {
        let (first, second) = peerA.fingerprint.hex <= peerB.fingerprint.hex
            ? (peerA, peerB)
            : (peerB, peerA)

        var input = Data("klyndro-sas-v1".utf8)
        input.append(contentsOf: first.fingerprint.hex.utf8)
        input.append(contentsOf: first.nonce.hex.utf8)
        input.append(contentsOf: second.fingerprint.hex.utf8)
        input.append(contentsOf: second.nonce.hex.utf8)

        let digestBytes = Array(SHA256.hash(data: input))
        self.digest = Fingerprint(digest: SHA256.hash(data: input))

        let value = (UInt32(digestBytes[0]) << 24)
            | (UInt32(digestBytes[1]) << 16)
            | (UInt32(digestBytes[2]) << 8)
            | UInt32(digestBytes[3])
        self.digits = String(format: "%06u", value % 1_000_000)
    }

    /// Confirms the peer computed the same digest. Digit equality alone is not enough.
    public func matches(digestHex: String) -> Bool {
        guard let peer = Fingerprint(hex: digestHex) else { return false }
        return digest.matches(peer)
    }
}
