import Foundation
import Testing
@testable import KlyndroKit

@Suite("Pairing QR code")
struct PairingQRCodeTests {

    private let sampleFingerprint = Fingerprint(hex: String(repeating: "ab", count: 32))!

    @Test("round trips a pairing URI with optional name")
    func roundTripWithOptionalName() throws {
        let original = PairingQRPayload(
            host: "192.168.23.101",
            port: 47823,
            fingerprint: sampleFingerprint,
            name: "Wandi MacBook"
        )
        let uri = try #require(original.encodeURI())
        let decoded = try #require(PairingQRPayload.parse(uri))
        #expect(decoded == original)
    }

    @Test("normalises uppercase fingerprint hex on parse")
    func normalisesFingerprint() throws {
        let uri = "klyndro://pair?v=1&host=192.168.1.20&port=47823&fp=\(String(repeating: "AB", count: 32))"
        let decoded = try #require(PairingQRPayload.parse(uri))
        #expect(decoded.fingerprint == sampleFingerprint)
        #expect(decoded.name == nil)
    }

    @Test("rejects wrong scheme, version, port, host, or fingerprint")
    func rejectsBadPayloads() {
        let validFP = sampleFingerprint.hex
        let badInputs = [
            "",
            "https://example.com/pair?v=1&host=192.168.1.2&port=47823&fp=\(validFP)",
            "klyndro://mirror?v=1&host=192.168.1.2&port=47823&fp=\(validFP)",
            "klyndro://pair?v=2&host=192.168.1.2&port=47823&fp=\(validFP)",
            "klyndro://pair?v=1&host=192.168.1.2&port=0&fp=\(validFP)",
            "klyndro://pair?v=1&host=192.168.1.2&port=70000&fp=\(validFP)",
            "klyndro://pair?v=1&host=&port=47823&fp=\(validFP)",
            "klyndro://pair?v=1&host=192.168.1.2&port=47823&fp=deadbeef",
        ]
        for raw in badInputs {
            #expect(PairingQRPayload.parse(raw) == nil, "should reject \(raw)")
        }
    }

    @Test("preferredIPv4 picks LAN en* address over tunnel and link-local")
    func preferredIPv4Ranking() {
        let candidates: [LocalNetworkAddress.InterfaceAddress] = [
            .init(name: "lo0", ip: "127.0.0.1"),
            .init(name: "utun4", ip: "100.64.0.1"),
            .init(name: "en0", ip: "169.254.10.2"),
            .init(name: "en0", ip: "192.168.23.101"),
        ]
        #expect(LocalNetworkAddress.preferredIPv4(from: candidates) == "192.168.23.101")
    }
}
