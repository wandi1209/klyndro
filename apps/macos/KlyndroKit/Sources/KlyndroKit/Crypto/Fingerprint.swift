import CryptoKit
import Foundation

/// A pinned peer identity: lowercase hex SHA-256 of the DER-encoded SubjectPublicKeyInfo.
///
/// The SPKI (not the whole certificate) is hashed so that re-issuing a certificate for the
/// same key does not invalidate trust. See protocol §5.4.
public struct Fingerprint: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 32
    public static let hexLength = 64

    /// 32 bytes, always lowercase hex on the wire.
    public let hex: String

    public init?(hex: String) {
        guard Self.isValidHex(hex) else { return nil }
        self.hex = hex.lowercased()
    }

    public init(digest: SHA256.Digest) {
        self.hex = Self.hexString(Array(digest))
    }

    public init(spki: some DataProtocol) {
        self.init(digest: SHA256.hash(data: Data(spki)))
    }

    public var description: String { hex }

    /// First 8 hex characters, for logs and UI. Never the full value in a log line.
    public var shortHex: String { String(hex.prefix(8)) }

    /// Constant-time comparison, for the confirmation step in protocol §7.
    public func matches(_ other: Fingerprint) -> Bool {
        Self.constantTimeEquals(hex, other.hex)
    }

    public static func isValidHex(_ value: String) -> Bool {
        guard value.count == hexLength else { return false }
        return value.allSatisfy(\.isHexDigit)
    }

    static func hexString(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Length-independent-ish constant time over the hex representation.
    ///
    /// Both inputs are fixed-length fingerprint hex strings, so an early return on a length
    /// difference leaks only that a value is malformed, which is already public.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}
