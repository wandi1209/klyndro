import Foundation
@testable import KlyndroKit
import Testing

@Suite("Pairing runner over an in-memory transport", .serialized)
struct PairingRunnerTests {
    private let macSPKI = Data("mac public key".utf8)
    private let androidSPKI = Data("android public key".utf8)

    private struct Harness {
        let mac: PairingRunner
        let android: PairingRunner
        let macStore: InMemoryTrustStore
        let androidStore: InMemoryTrustStore
        let macEvents: EventRecorder
        let androidEvents: EventRecorder
    }

    private func makeHarness(
        macFingerprint: Fingerprint? = nil,
        androidFingerprint: Fingerprint? = nil
    ) async -> Harness {
        let (macTransport, androidTransport) = FrameTransportLoopback.makePair()
        // Each side sees the other's key, exactly as the TLS layer would report it.
        macTransport.peerPublicKey = androidSPKI
        androidTransport.peerPublicKey = macSPKI

        let macStore = InMemoryTrustStore()
        let androidStore = InMemoryTrustStore()

        let macLocal = PairingLocalInfo(
            deviceID: DeviceID(),
            name: "Test Mac",
            platform: .macos,
            capabilities: [.clipboard],
            fingerprint: macFingerprint ?? Fingerprint(spki: macSPKI)
        )
        let androidLocal = PairingLocalInfo(
            deviceID: DeviceID(),
            name: "Test Phone",
            platform: .android,
            capabilities: [.clipboard],
            fingerprint: androidFingerprint ?? Fingerprint(spki: androidSPKI)
        )

        let mac = PairingRunner(
            transport: macTransport,
            local: macLocal,
            role: .initiator,
            trustStore: macStore,
            window: PairingWindow()
        )
        let android = PairingRunner(
            transport: androidTransport,
            local: androidLocal,
            role: .responder,
            trustStore: androidStore,
            window: PairingWindow()
        )

        let macEvents = EventRecorder()
        let androidEvents = EventRecorder()
        await macEvents.consumePairing(await mac.events())
        await androidEvents.consumePairing(await android.events())

        return Harness(
            mac: mac,
            android: android,
            macStore: macStore,
            androidStore: androidStore,
            macEvents: macEvents,
            androidEvents: androidEvents
        )
    }

    @Test("both devices show the same code and persist each other")
    func happyPath() async {
        let harness = await makeHarness()
        await harness.mac.start()
        await harness.android.start()

        let bothShowCode = await pollUntil {
            let macCode = await harness.macEvents.pairingCode()
            let androidCode = await harness.androidEvents.pairingCode()
            return macCode != nil && androidCode != nil
        }
        #expect(bothShowCode, "both sides must surface a code")

        let macCode = await harness.macEvents.pairingCode()
        let androidCode = await harness.androidEvents.pairingCode()
        #expect(macCode == androidCode, "the two devices must display identical digits")
        #expect(macCode?.count == 6)

        await harness.mac.confirm()
        await harness.android.confirm()

        let macPaired = await pollUntil { await harness.macEvents.pairedPeer() != nil }
        let androidPaired = await pollUntil { await harness.androidEvents.pairedPeer() != nil }
        #expect(macPaired)
        #expect(androidPaired)

        let macPeers = try? harness.macStore.allPeers()
        let androidPeers = try? harness.androidStore.allPeers()
        #expect(macPeers?.count == 1)
        #expect(androidPeers?.count == 1)
        #expect(macPeers?.first?.fingerprint == Fingerprint(spki: androidSPKI).hex)
        #expect(androidPeers?.first?.fingerprint == Fingerprint(spki: macSPKI).hex)
        #expect(macPeers?.first?.platform == "android")
    }

    @Test("a device that claims a fingerprint it does not hold is rejected")
    func rejectsForgedFingerprint() async {
        // The peer claims a key that is not the one TLS observed for the connection.
        let harness = await makeHarness(
            androidFingerprint: Fingerprint(spki: Data("a key the peer does not hold".utf8))
        )
        await harness.mac.start()
        await harness.android.start()

        let failed = await pollUntil {
            let macFailed = await harness.macEvents.pairingFailure() != nil
            let androidFailed = await harness.androidEvents.pairingFailure() != nil
            return macFailed || androidFailed
        }
        #expect(failed, "a mismatched fingerprint must abort pairing")

        let macPeers = try? harness.macStore.allPeers()
        let androidPeers = try? harness.androidStore.allPeers()
        #expect(macPeers?.isEmpty == true, "nothing may be persisted on failure")
        #expect(androidPeers?.isEmpty == true)
    }

    @Test("a user rejection persists nothing")
    func userRejectionPersistsNothing() async {
        let harness = await makeHarness()
        await harness.mac.start()
        await harness.android.start()

        _ = await pollUntil { await harness.macEvents.pairingCode() != nil }
        await harness.mac.reject()

        let failed = await pollUntil { await harness.macEvents.pairingFailure() != nil }
        #expect(failed)

        let macPeers = try? harness.macStore.allPeers()
        #expect(macPeers?.isEmpty == true)
    }

    @Test("pairing outside the window is refused")
    func closedWindowIsRefused() async {
        let (macTransport, _) = FrameTransportLoopback.makePair()
        macTransport.peerPublicKey = androidSPKI

        let runner = PairingRunner(
            transport: macTransport,
            local: PairingLocalInfo(
                deviceID: DeviceID(),
                name: "Late Mac",
                platform: .macos,
                capabilities: [],
                fingerprint: Fingerprint(spki: macSPKI)
            ),
            role: .initiator,
            trustStore: InMemoryTrustStore(),
            window: PairingWindow(openedAt: Date().addingTimeInterval(-3600))
        )
        let events = EventRecorder()
        await events.consumePairing(await runner.events())
        await runner.start()

        let failed = await pollUntil { await events.pairingFailure() != nil }
        #expect(failed)
        #expect(await events.pairingFailure() == .windowClosed)
    }
}

