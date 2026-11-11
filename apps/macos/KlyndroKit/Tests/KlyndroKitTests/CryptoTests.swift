import CryptoKit
import Foundation
@testable import KlyndroKit
import Testing

@Suite("Fingerprints and nonces")
struct FingerprintTests {
    @Test("accepts a 64-character hex fingerprint and normalises case")
    func acceptsValidHex() throws {
        let upper = String(repeating: "AB", count: 32)
        let fingerprint = try #require(Fingerprint(hex: upper))
        #expect(fingerprint.hex == upper.lowercased())
        #expect(fingerprint.hex.count == Fingerprint.hexLength)
    }

    @Test("rejects wrong length, non-hex, and empty input")
    func rejectsInvalidHex() {
        #expect(Fingerprint(hex: "") == nil)
        #expect(Fingerprint(hex: String(repeating: "a", count: 63)) == nil)
        #expect(Fingerprint(hex: String(repeating: "a", count: 65)) == nil)
        #expect(Fingerprint(hex: String(repeating: "z", count: 64)) == nil)
        #expect(Fingerprint(hex: String(repeating: "g", count: 64)) == nil)
    }

    @Test("hashes the SubjectPublicKeyInfo, not the certificate")
    func hashesSPKI() {
        let spki = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
        let expected = SHA256.hash(data: spki)
        let fingerprint = Fingerprint(spki: spki)
        #expect(fingerprint.hex == Fingerprint.hexString(Array(expected)))
    }

    @Test("matches() is true only for identical values")
    func matches() throws {
        let a = try #require(Fingerprint(hex: String(repeating: "a", count: 64)))
        let b = try #require(Fingerprint(hex: String(repeating: "b", count: 64)))
        #expect(a.matches(a))
        #expect(!a.matches(b))
    }

    @Test("short form exposes only eight characters")
    func shortForm() throws {
        let fingerprint = try #require(Fingerprint(hex: String(repeating: "ab", count: 32)))
        #expect(fingerprint.shortHex == "abababab")
    }

    @Test("nonces are 16 bytes of hex and differ between calls")
    func nonceGeneration() {
        let first = Nonce()
        let second = Nonce()
        #expect(first.hex.count == 32)
        let allHex = first.hex.allSatisfy(\.isHexDigit)
        #expect(allHex)
        #expect(first.hex != second.hex)
    }

    @Test("nonce parsing rejects bad input")
    func nonceParsing() {
        #expect(Nonce(hex: "00") == nil)
        #expect(Nonce(hex: String(repeating: "z", count: 32)) == nil)
        #expect(Nonce(hex: String(repeating: "0", count: 32)) != nil)
    }
}

@Suite("Pairing code (SAS)")
struct PairingCodeTests {
    struct Vector: Decodable {
        struct Party: Decodable {
            let fingerprint: String
            let nonce: String
        }
        let name: String
        let peerA: Party
        let peerB: Party
        let code: String
        let digest: String
        let swappedMustMatch: Bool

        enum CodingKeys: String, CodingKey {
            case name, code, digest
            case peerA = "peer_a"
            case peerB = "peer_b"
            case swappedMustMatch = "swapped_must_match"
        }
    }

    struct Document: Decodable {
        let vectors: [Vector]
    }

    static func loadVectors() throws -> [Vector] {
        var url = URL(filePath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let file = url.appending(path: "protocol/vectors/pairing-sas.json")
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: file)).vectors
    }

    @Test("reproduces the independently computed vectors")
    func matchesSharedVectors() throws {
        let vectors = try Self.loadVectors()
        #expect(!vectors.isEmpty)

        for vector in vectors {
            let a = (
                fingerprint: try #require(Fingerprint(hex: vector.peerA.fingerprint)),
                nonce: try #require(Nonce(hex: vector.peerA.nonce))
            )
            let b = (
                fingerprint: try #require(Fingerprint(hex: vector.peerB.fingerprint)),
                nonce: try #require(Nonce(hex: vector.peerB.nonce))
            )

            let code = PairingCode(peerA: a, peerB: b)
            #expect(code.digits == vector.code, "\(vector.name): code mismatch")
            #expect(code.digest.hex == vector.digest, "\(vector.name): digest mismatch")

            if vector.swappedMustMatch {
                let swapped = PairingCode(peerA: b, peerB: a)
                #expect(swapped.digits == code.digits, "ordering must not change the code")
                #expect(swapped.digest.matches(code.digest))
            }
        }
    }

    @Test("always produces exactly six digits")
    func sixDigits() {
        for _ in 0..<50 {
            let code = PairingCode(
                peerA: (Fingerprint(spki: Data(Nonce().hex.utf8)), Nonce()),
                peerB: (Fingerprint(spki: Data(Nonce().hex.utf8)), Nonce())
            )
            #expect(code.digits.count == 6)
            let allDigits = code.digits.allSatisfy(\.isNumber)
            #expect(allDigits)
        }
    }

    @Test("rejects a digest that differs in a single character")
    func rejectsNearMiss() throws {
        let a = (fingerprint: Fingerprint(spki: Data("a".utf8)), nonce: Nonce())
        let b = (fingerprint: Fingerprint(spki: Data("b".utf8)), nonce: Nonce())
        let code = PairingCode(peerA: a, peerB: b)

        #expect(code.matches(digestHex: code.digest.hex))

        var tampered = Array(code.digest.hex)
        tampered[0] = tampered[0] == "0" ? "1" : "0"
        #expect(!code.matches(digestHex: String(tampered)))
        #expect(!code.matches(digestHex: "not-hex"))
    }
}
