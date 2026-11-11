import Foundation
@testable import KlyndroKit
import Testing

@Suite("Discovery records")
struct DiscoveryTests {
    private let deviceID = DeviceID(hex: "a1b2c3d4e5f60718")!
    private let fingerprint = Fingerprint(spki: Data("phone key".utf8))

    @Test("TXT records survive an encode/decode round trip")
    func txtRoundTrip() {
        let fields = ["id": deviceID.hex, "name": "Pixel", "proto": "1", "caps": "clipboard"]
        let encoded = TXTRecord.encode(fields)
        #expect(TXTRecord.decode(encoded) == fields)
    }

    @Test("TXT encoding is sorted and deterministic")
    func txtIsDeterministic() {
        let a = TXTRecord.encode(["b": "2", "a": "1"])
        let b = TXTRecord.encode(["a": "1", "b": "2"])
        #expect(a == b)
    }

    @Test("TXT decoding tolerates truncation and junk")
    func txtToleratesBadInput() {
        #expect(TXTRecord.decode(Data()).isEmpty)
        // Claims 200 bytes, supplies 3.
        #expect(TXTRecord.decode(Data([200, 0x61, 0x3D, 0x62])).isEmpty)
        // No '=' separator at all.
        #expect(TXTRecord.decode(Data([3, 0x61, 0x62, 0x63])).isEmpty)
    }

    @Test("parses a complete advertisement")
    func parsesAdvertisement() {
        let fields = DiscoveredPeer.advertisementFields(
            deviceID: deviceID,
            name: "Redmi Note 13",
            fingerprint: fingerprint,
            capabilities: [.clipboard, .notifications]
        )

        let peer = DiscoveredPeer.parse(serviceName: "Redmi", fields: fields)
        #expect(peer?.deviceID == deviceID)
        #expect(peer?.name == "Redmi Note 13")
        #expect(peer?.fingerprint == fingerprint)
        #expect(peer?.capabilities == [.clipboard, .notifications])
        #expect(peer?.isPaired == false)
    }

    @Test("marks a peer paired only when its device id is trusted")
    func marksPaired() {
        let fields = DiscoveredPeer.advertisementFields(
            deviceID: deviceID,
            name: "Redmi",
            fingerprint: fingerprint,
            capabilities: []
        )
        let trusted = TrustedPeer(
            deviceID: deviceID.hex,
            name: "Redmi",
            platform: "android",
            fingerprint: fingerprint.hex
        )
        #expect(DiscoveredPeer.parse(serviceName: "s", fields: fields, trustedPeers: [trusted])?.isPaired == true)
    }

    @Test("rejects advertisements with missing or malformed fields")
    func rejectsIncompleteAdvertisements() {
        let complete = DiscoveredPeer.advertisementFields(
            deviceID: deviceID,
            name: "Redmi",
            fingerprint: fingerprint,
            capabilities: []
        )

        for key in ["id", "name", "fp", "proto"] {
            var broken = complete
            broken[key] = nil
            #expect(DiscoveredPeer.parse(serviceName: "s", fields: broken) == nil,
                    "missing \(key) must be rejected")
        }

        var wrongVersion = complete
        wrongVersion["proto"] = "2"
        #expect(DiscoveredPeer.parse(serviceName: "s", fields: wrongVersion) == nil)

        var badFingerprint = complete
        badFingerprint["fp"] = "zz"
        #expect(DiscoveredPeer.parse(serviceName: "s", fields: badFingerprint) == nil)

        var emptyName = complete
        emptyName["name"] = ""
        #expect(DiscoveredPeer.parse(serviceName: "s", fields: emptyName) == nil)
    }

    @Test("caps the advertised name length")
    func capsNameLength() {
        let fields = DiscoveredPeer.advertisementFields(
            deviceID: deviceID,
            name: String(repeating: "x", count: 400),
            fingerprint: fingerprint,
            capabilities: []
        )
        #expect(fields["name"]?.utf8.count == HandshakeCodec.maximumDeviceNameBytes)
    }

    @Test("a publishable service carries this device's advertisement")
    func serviceAdvertisement() {
        let service = BonjourDiscovery.service(
            deviceID: deviceID,
            name: "Mac",
            fingerprint: fingerprint,
            capabilities: [.clipboard]
        )
        // Network.framework does not expose the service fields for reading, so this asserts the
        // factory produces a service at all; the TXT contents are covered above.
        #expect(service.type == DiscoveredPeer.serviceType)
    }
}
