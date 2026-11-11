import Foundation
@testable import KlyndroKit
import Testing

/// End-to-end TLS on the loopback interface: real TLS 1.3 handshake, real certificates, real
/// pinning decisions. This is the closest thing to a device test that can run without a phone.
@Suite("TLS loopback", .serialized, .timeLimit(.minutes(2)))
struct TLSIntegrationTests {
    private final class ListenerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: KlyndroListener?

        var listener: KlyndroListener? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private func makeIdentity(_ name: String) throws -> (DeviceIdentity, String) {
        let tag = "id.my.wandidev.klyndro.tls.\(UUID().uuidString)"
        let identity = try KeychainTestGate.run { try DeviceIdentityStore.create(commonName: name, tag: tag) }
        return (identity, tag)
    }

    private func serverInfo(for identity: DeviceIdentity, name: String) -> LocalDeviceInfo {
        LocalDeviceInfo(
            deviceID: DeviceID(),
            name: name,
            platform: .macos,
            appVersion: "0.1.0-test",
            capabilities: [.clipboard, .mirroring],
            fingerprint: identity.fingerprint
        )
    }

    private func clientInfo(for identity: DeviceIdentity) -> LocalDeviceInfo {
        LocalDeviceInfo(
            deviceID: DeviceID(),
            name: "Test Phone",
            platform: .android,
            appVersion: "0.1.0-test",
            capabilities: [.clipboard],
            fingerprint: identity.fingerprint
        )
    }

    @Test("mutual TLS with pinned keys authenticates both sides")
    func pinnedMutualTLSAuthenticates() async throws {
        let (serverIdentity, serverTag) = try makeIdentity("Loopback Server")
        let (clientIdentity, clientTag) = try makeIdentity("Loopback Client")
        defer {
            KeychainTestGate.run { try? DeviceIdentityStore.delete(tag: serverTag) }
            KeychainTestGate.run { try? DeviceIdentityStore.delete(tag: clientTag) }
        }

        let serverRecorder = EventRecorder()
        let box = ListenerBox()

        let listener = try KlyndroListener(
            identity: serverIdentity,
            policy: PinPolicy(mode: .pinned([clientIdentity.fingerprint]))
        ) { transport in
            let session = PeerSession(
                transport: transport,
                local: self.serverInfo(for: serverIdentity, name: "Loopback Mac"),
                role: .responder
            )
            Task {
                let events = await session.events()
                await serverRecorder.consume(events)
                await session.start()
            }
        }
        box.listener = listener
        try await listener.start()
        defer { listener.stop() }

        let port = try #require(listener.port, "listener did not bind a port")

        let clientTransport = try await KlyndroDialer.connect(
            host: "127.0.0.1",
            port: port,
            identity: clientIdentity,
            policy: PinPolicy(mode: .pinned([serverIdentity.fingerprint]))
        )
        let clientSession = PeerSession(
            transport: clientTransport,
            local: clientInfo(for: clientIdentity),
            role: .initiator
        )
        let clientRecorder = EventRecorder()
        await clientRecorder.consume(await clientSession.events())
        await clientSession.start()

        let established = await pollUntil(timeout: .seconds(10)) {
            let clientReady = await clientRecorder.established() != nil
            let serverReady = await serverRecorder.established() != nil
            return clientReady && serverReady
        }
        #expect(established, "both sides must authenticate over real TLS")

        let clientView = await clientRecorder.established()
        let serverView = await serverRecorder.established()

        // The fingerprint must come from the certificate the peer actually presented.
        #expect(clientView?.fingerprint.matches(serverIdentity.fingerprint) == true)
        #expect(serverView?.fingerprint.matches(clientIdentity.fingerprint) == true)
        #expect(clientView?.negotiated == [.clipboard])
        #expect(clientView?.platform == .macos)

        await clientSession.close()
    }

    @Test("a peer with an untrusted certificate is disconnected")
    func rejectsUnpinnedPeer() async throws {
        let (serverIdentity, serverTag) = try makeIdentity("Reject Server")
        let (clientIdentity, clientTag) = try makeIdentity("Reject Client")
        defer {
            KeychainTestGate.run { try? DeviceIdentityStore.delete(tag: serverTag) }
            KeychainTestGate.run { try? DeviceIdentityStore.delete(tag: clientTag) }
        }

        let serverRecorder = EventRecorder()
        let listener = try KlyndroListener(
            identity: serverIdentity,
            policy: PinPolicy(mode: .pinned([clientIdentity.fingerprint]))
        ) { transport in
            let session = PeerSession(
                transport: transport,
                local: self.serverInfo(for: serverIdentity, name: "Reject Mac"),
                role: .responder
            )
            Task {
                let events = await session.events()
                await serverRecorder.consume(events)
                await session.start()
            }
        }
        try await listener.start()
        defer { listener.stop() }

        let port = try #require(listener.port)

        // The client trusts a key that is not the server's.
        let stranger = Fingerprint(spki: Data("not the server key".utf8))
        await #expect(throws: (any Error).self) {
            _ = try await KlyndroDialer.connect(
                host: "127.0.0.1",
                port: port,
                identity: clientIdentity,
                policy: PinPolicy(mode: .pinned([stranger])),
                timeout: 5
            )
        }
    }

    @Test("a server that does not trust the client never authenticates it")
    func rejectsUnpinnedClient() async throws {
        let (serverIdentity, serverTag) = try makeIdentity("Strict Server")
        let (clientIdentity, clientTag) = try makeIdentity("Unvetted Client")
        defer {
            KeychainTestGate.run { try? DeviceIdentityStore.delete(tag: serverTag) }
            KeychainTestGate.run { try? DeviceIdentityStore.delete(tag: clientTag) }
        }

        let listener = try KlyndroListener(
            identity: serverIdentity,
            policy: PinPolicy(mode: .pinned([Fingerprint(spki: Data("someone else".utf8))]))
        ) { transport in
            let session = PeerSession(
                transport: transport,
                local: self.serverInfo(for: serverIdentity, name: "Strict Mac"),
                role: .responder
            )
            Task { await session.start() }
        }
        try await listener.start()
        defer { listener.stop() }

        let port = try #require(listener.port)

        // TLS 1.3 lets the client believe the handshake finished before the server has judged
        // its certificate, so the guarantee is "never authenticated", not "connect() throws".
        // Both outcomes are acceptable; silently establishing a session is not.
        let transport: NWFrameTransport
        do {
            transport = try await KlyndroDialer.connect(
                host: "127.0.0.1",
                port: port,
                identity: clientIdentity,
                policy: PinPolicy(mode: .pinned([serverIdentity.fingerprint])),
                timeout: 10
            )
        } catch {
            // Rejected during the TLS handshake. Fine.
            return
        }

        let session = PeerSession(
            transport: transport,
            local: self.clientInfo(for: clientIdentity),
            role: .initiator
        )
        let recorder = EventRecorder()
        await recorder.consume(await session.events())
        await session.start()

        let closed = await pollUntil(timeout: .seconds(10)) { await recorder.closeReason() != nil }
        #expect(closed, "an untrusted client must not hang")
        let established = await recorder.established()
        #expect(established == nil, "an untrusted client must never authenticate")
    }
}
