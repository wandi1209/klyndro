import Foundation

/// Feature flags exchanged in `hello` (protocol §5.1).
public enum Capability: String, Sendable, CaseIterable, Codable {
    case clipboard
    case clipboardSensitive = "clipboard.sensitive"
    case notifications
    case fileTransfer = "file-transfer"
    case mirroring
    case presence

    /// Unknown capability strings from a newer peer are ignored, not rejected.
    public static func parse(_ values: [String]) -> [Capability] {
        let known = values.compactMap(Capability.init(rawValue:))
        // Preserve a stable order so negotiated output is comparable in tests.
        return Capability.allCases.filter { known.contains($0) }
    }

    /// Intersection, in `allCases` order. Used to decide what a session may do.
    public static func negotiate(local: [Capability], remote: [Capability]) -> [Capability] {
        Capability.allCases.filter { local.contains($0) && remote.contains($0) }
    }
}

/// Platform identifier used on the wire.
public enum Platform: String, Sendable, Codable, CaseIterable {
    case macos
    case android
}

/// Stable device identifier: 16 lowercase hex characters, generated once per installation.
public struct DeviceID: Hashable, Sendable, CustomStringConvertible {
    public static let hexLength = 16

    public let hex: String

    public init?(hex: String) {
        guard hex.count == Self.hexLength, hex.allSatisfy(\.isHexDigit) else { return nil }
        self.hex = hex.lowercased()
    }

    public init(random: Void = ()) {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<8).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        self.hex = Fingerprint.hexString(bytes)
    }

    public var description: String { hex }
}
