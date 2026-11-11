import Foundation
@testable import KlyndroKit
import Testing

@Suite("Device identity and trust store", .serialized)
struct IdentityTests {
    private static func uniqueTag(_ prefix: String) -> String {
        "\(prefix).\(UUID().uuidString)"
    }

    @Test("creates a usable identity, reloads it, and deletes it")
    func createLoadDelete() throws {
        let tag = Self.uniqueTag("id.my.wandidev.klyndro.test")
        defer { KeychainTestGate.run { try? DeviceIdentityStore.delete(tag: tag) } }

        let created = try KeychainTestGate.run { try DeviceIdentityStore.create(commonName: "Test Mac", tag: tag) }
        #expect(created.fingerprint.hex.count == 64)
        let allHex = created.fingerprint.hex.allSatisfy(\.isHexDigit)
        #expect(allHex)
        #expect(created.commonName.contains("Test Mac"))
        #expect(!created.certificateDER.isEmpty)

        let loaded = try #require(KeychainTestGate.run { try DeviceIdentityStore.load(tag: tag) })
        #expect(loaded.fingerprint.matches(created.fingerprint),
                "the reloaded identity must keep the same pinned fingerprint")
        #expect(loaded.certificateDER == created.certificateDER)

        try DeviceIdentityStore.delete(tag: tag)
        let afterDelete = try KeychainTestGate.run { try DeviceIdentityStore.load(tag: tag) }
        #expect(afterDelete == nil)
    }

    @Test("loadOrCreate is idempotent")
    func loadOrCreateIsStable() throws {
        let tag = Self.uniqueTag("id.my.wandidev.klyndro.test")
        defer { KeychainTestGate.run { try? DeviceIdentityStore.delete(tag: tag) } }

        let first = try KeychainTestGate.run { try DeviceIdentityStore.loadOrCreate(commonName: "Test Mac", tag: tag) }
        let second = try KeychainTestGate.run { try DeviceIdentityStore.loadOrCreate(commonName: "Test Mac", tag: tag) }
        #expect(first.fingerprint.matches(second.fingerprint))
        #expect(first.certificateDER == second.certificateDER)
    }

    @Test("fingerprints different keys differently")
    func distinctKeysDistinctFingerprints() throws {
        let tagA = Self.uniqueTag("id.my.wandidev.klyndro.test")
        let tagB = Self.uniqueTag("id.my.wandidev.klyndro.test")
        defer {
            KeychainTestGate.run { try? DeviceIdentityStore.delete(tag: tagA) }
            KeychainTestGate.run { try? DeviceIdentityStore.delete(tag: tagB) }
        }

        let a = try KeychainTestGate.run { try DeviceIdentityStore.create(commonName: "A", tag: tagA) }
        let b = try KeychainTestGate.run { try DeviceIdentityStore.create(commonName: "B", tag: tagB) }
        #expect(!a.fingerprint.matches(b.fingerprint))
    }

    @Test("rejects a certificate it cannot parse")
    func rejectsGarbageCertificate() {
        #expect(throws: IdentityError.self) {
            _ = try DeviceIdentityStore.fingerprint(ofCertificateDER: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        }
    }
}

@Suite("Trust store", .serialized)
struct TrustStoreTests {
    private static func uniqueService() -> String {
        "id.my.wandidev.klyndro.trust.test.\(UUID().uuidString)"
    }

    private static func peer(_ id: String = "a1b2c3d4e5f60718") -> TrustedPeer {
        TrustedPeer(
            deviceID: id,
            name: "Test Android",
            platform: "android",
            fingerprint: String(repeating: "ab", count: 32),
            lastHost: "192.0.2.10",
            lastPort: 47_823
        )
    }

    @Test("round trips peers through the keychain")
    func keychainRoundTrip() throws {
        try KeychainTestGate.run {
            let store = KeychainTrustStore(service: Self.uniqueService())
            defer { try? store.removeAll() }

            #expect(try store.allPeers().isEmpty)

            let peer = Self.peer()
            try store.upsert(peer)
            #expect(try store.allPeers() == [peer])
            #expect(try store.peer(id: peer.deviceID) == peer)

            var updated = peer
            updated.name = "Renamed"
            try store.upsert(updated)
            #expect(try store.allPeers().count == 1)
            #expect(try store.peer(id: peer.deviceID)?.name == "Renamed")

            try store.remove(id: peer.deviceID)
            #expect(try store.allPeers().isEmpty)
        }
    }

    @Test("in-memory store has the same semantics")
    func inMemorySemantics() throws {
        let store = InMemoryTrustStore()
        let peer = Self.peer()
        try store.upsert(peer)
        try store.upsert(Self.peer())
        #expect(try store.allPeers().count == 1)
        try store.remove(id: peer.deviceID)
        #expect(try store.allPeers().isEmpty)
    }

    @Test("a peer only authorises its own fingerprint")
    func peerAuthorisesItsFingerprint() throws {
        let peer = Self.peer()
        let own = try #require(peer.fingerprintValue)
        let other = Fingerprint(spki: Data("another key".utf8))

        #expect(peer.authorises(own))
        #expect(!peer.authorises(other))
    }

    @Test("a malformed stored fingerprint authorises nothing")
    func malformedFingerprintAuthorisesNothing() {
        var peer = Self.peer()
        peer.fingerprint = "not-hex"
        #expect(!peer.authorises(Fingerprint(spki: Data("x".utf8))))
    }
}

@Suite("Pin policy")
struct PinPolicyTests {
    private static func makeCertificate(_ commonName: String) throws -> (Data, Fingerprint) {
        let certificate = try DeviceIdentityStore.makeEphemeralCertificate(commonName: commonName)
        return (certificate.der, certificate.fingerprint)
    }

    @Test("accepts a pinned fingerprint")
    func acceptsPinned() throws {
        let (der, fingerprint) = try Self.makeCertificate("Peer")

        let policy = PinPolicy.pinned([fingerprint])
        let decision = policy.evaluate(peerCertificateDER: der)

        #expect(decision.isAccepted)
        #expect(decision.fingerprint?.matches(fingerprint) == true)
    }

    @Test("rejects an unpinned fingerprint")
    func rejectsUnpinned() throws {
        let (der, _) = try Self.makeCertificate("Stranger")

        let stranger = Fingerprint(spki: Data("someone else".utf8))
        let decision = PinPolicy.pinned([stranger]).evaluate(peerCertificateDER: der)

        guard case .rejected(.fingerprintNotTrusted) = decision else {
            Issue.record("expected fingerprintNotTrusted, got \(decision)")
            return
        }
    }

    @Test("rejects everything when nothing is paired")
    func rejectsWhenNothingPaired() throws {
        let (der, _) = try Self.makeCertificate("Peer")

        let decision = PinPolicy.pinned([]).evaluate(peerCertificateDER: der)
        #expect(decision == .rejected(.noPairedPeers))
    }

    @Test("the pairing window accepts an unknown but readable certificate")
    func pairingWindowAcceptsUnknown() throws {
        let (der, fingerprint) = try Self.makeCertificate("New Phone")

        let decision = PinPolicy.pairingOnly.evaluate(peerCertificateDER: der)
        #expect(decision.isAccepted)
        #expect(decision.fingerprint?.matches(fingerprint) == true)
        guard case .accepted(_, let isPinned) = decision else {
            Issue.record("expected acceptance")
            return
        }
        #expect(!isPinned, "a pairing-window peer is authenticated per-connection, not pinned")
    }

    @Test("rejects an unreadable certificate in both modes")
    func rejectsUnparsable() {
        let garbage = Data([0x00, 0x01, 0x02])
        #expect(PinPolicy.pairingOnly.evaluate(peerCertificateDER: garbage) == .rejected(.unparsableCertificate))
        #expect(PinPolicy.pinned([]).evaluate(peerCertificateDER: garbage) == .rejected(.unparsableCertificate))
    }

    @Test("pinned policy can be built from trusted peers")
    func policyFromPeers() throws {
        let (der, fingerprint) = try Self.makeCertificate("Peer")

        let peer = TrustedPeer(
            deviceID: "a1b2c3d4e5f60718",
            name: "Peer",
            platform: "android",
            fingerprint: fingerprint.hex
        )
        #expect(PinPolicy.pinned([peer]).evaluate(peerCertificateDER: der).isAccepted)
    }
}
