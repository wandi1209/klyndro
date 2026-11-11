import Foundation
import Security

/// A device the user has explicitly paired with.
public struct TrustedPeer: Codable, Sendable, Equatable, Identifiable {
    public var deviceID: String
    public var name: String
    public var platform: String
    /// Lowercase hex SHA-256 of the peer's SubjectPublicKeyInfo.
    public var fingerprint: String
    public var lastHost: String?
    public var lastPort: Int?
    public var pairedAt: Date

    public var id: String { deviceID }

    public init(
        deviceID: String,
        name: String,
        platform: String,
        fingerprint: String,
        lastHost: String? = nil,
        lastPort: Int? = nil,
        pairedAt: Date = Date()
    ) {
        self.deviceID = deviceID
        self.name = name
        self.platform = platform
        self.fingerprint = fingerprint
        self.lastHost = lastHost
        self.lastPort = lastPort
        self.pairedAt = pairedAt
    }

    public var fingerprintValue: Fingerprint? { Fingerprint(hex: fingerprint) }

    /// True when this record authorises a peer presenting `fingerprint`.
    public func authorises(_ candidate: Fingerprint) -> Bool {
        fingerprintValue?.matches(candidate) ?? false
    }
}

/// Persistence for paired devices.
///
/// Implementations store public identity data only: device ID, display name, platform,
/// public-key fingerprint, and last known address.
public protocol TrustStore: Sendable {
    func allPeers() throws -> [TrustedPeer]
    func peer(id: String) throws -> TrustedPeer?
    func upsert(_ peer: TrustedPeer) throws
    func remove(id: String) throws
    func removeAll() throws
}

/// Keychain-backed trust store.
///
/// Uses the login Keychain, not the data protection Keychain: `kSecUseDataProtectionKeychain`
/// requires a keychain-access-group entitlement, and this app is ad-hoc signed and unsandboxed
/// (ADR 0006, ADR 0008). The item is a generic password holding a small JSON array of public
/// identity records — never a private key.
public struct KeychainTrustStore: TrustStore {
    public static let defaultService = "id.my.wandidev.klyndro.trust"
    private static let account = "paired-peers"

    private let service: String

    public init(service: String = KeychainTrustStore.defaultService) {
        self.service = service
    }

    public func allPeers() throws -> [TrustedPeer] {
        guard let data = try readData() else { return [] }
        // A corrupt record means "no paired devices", not a crash: the user can pair again,
        // and acting on half-decoded trust data would be worse.
        return (try? JSONDecoder().decode([TrustedPeer].self, from: data)) ?? []
    }

    public func peer(id: String) throws -> TrustedPeer? {
        try allPeers().first { $0.deviceID == id }
    }

    public func upsert(_ peer: TrustedPeer) throws {
        var peers = try allPeers()
        if let index = peers.firstIndex(where: { $0.deviceID == peer.deviceID }) {
            peers[index] = peer
        } else {
            peers.append(peer)
        }
        try write(peers)
    }

    public func remove(id: String) throws {
        var peers = try allPeers()
        peers.removeAll { $0.deviceID == id }
        try write(peers)
    }

    public func removeAll() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TrustStoreError.keychainFailure(operation: "delete", status: status)
        }
    }

    // MARK: - Keychain plumbing

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account
        ]
    }

    private func readData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw TrustStoreError.keychainFailure(operation: "read", status: status)
        }
    }

    private func write(_ peers: [TrustedPeer]) throws {
        let data = try JSONEncoder().encode(peers)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TrustStoreError.keychainFailure(operation: "update", status: updateStatus)
        }

        var insert = baseQuery()
        insert[kSecValueData as String] = data
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TrustStoreError.keychainFailure(operation: "add", status: addStatus)
        }
    }
}

/// Non-persistent store for tests and previews.
public final class InMemoryTrustStore: TrustStore, @unchecked Sendable {
    private var peers: [TrustedPeer]
    private let lock = NSLock()

    public init(peers: [TrustedPeer] = []) {
        self.peers = peers
    }

    public func allPeers() throws -> [TrustedPeer] {
        lock.lock()
        defer { lock.unlock() }
        return peers
    }

    public func peer(id: String) throws -> TrustedPeer? {
        try allPeers().first { $0.deviceID == id }
    }

    public func upsert(_ peer: TrustedPeer) throws {
        lock.lock()
        defer { lock.unlock() }
        if let index = peers.firstIndex(where: { $0.deviceID == peer.deviceID }) {
            peers[index] = peer
        } else {
            peers.append(peer)
        }
    }

    public func remove(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        peers.removeAll { $0.deviceID == id }
    }

    public func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        peers.removeAll()
    }
}

public enum TrustStoreError: Error, CustomStringConvertible {
    case keychainFailure(operation: String, status: OSStatus)

    public var description: String {
        switch self {
        case .keychainFailure(let operation, let status):
            return "trust store \(operation) failed (status \(status))"
        }
    }
}
