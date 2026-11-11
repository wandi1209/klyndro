import Foundation
@testable import KlyndroKit
import Testing

@Suite("Peer session over an in-memory transport", .serialized)
struct PeerSessionTests {
    private struct Harness {
        let client: PeerSession
        let server: PeerSession
        let clientEvents: EventRecorder
        let serverEvents: EventRecorder
        let clientTransport: InMemoryFrameTransport
        let serverTransport: InMemoryFrameTransport
    }

    private func makeHarness(
        clientCapabilities: [Capability] = [.clipboard, .mirroring, .notifications],
        serverCapabilities: [Capability] = [.clipboard, .notifications],
        heartbeatInterval: Duration = .seconds(15),
        deadAfter: TimeInterval = 45
    ) async -> Harness {
        let (clientTransport, serverTransport) = FrameTransportLoopback.makePair()

        // Simulate what the TLS layer reports for each side.
        let clientSPKI = Data("client public key".utf8)
        let serverSPKI = Data("server public key".utf8)
        clientTransport.peerPublicKey = serverSPKI
        serverTransport.peerPublicKey = clientSPKI

        let clientInfo = makeDeviceInfo(
            name: "Mac",
            platform: .macos,
            capabilities: clientCapabilities
        )
        let serverInfo = makeDeviceInfo(
            name: "Android",
            platform: .android,
            capabilities: serverCapabilities
        )

        let client = PeerSession(
            transport: clientTransport,
            local: clientInfo,
            role: .initiator,
            heartbeatInterval: heartbeatInterval,
            deadAfter: deadAfter
        )
        let server = PeerSession(
            transport: serverTransport,
            local: serverInfo,
            role: .responder,
            heartbeatInterval: heartbeatInterval,
            deadAfter: deadAfter
        )

        let clientEvents = EventRecorder()
        let serverEvents = EventRecorder()
        await clientEvents.consume(await client.events())
        await serverEvents.consume(await server.events())

        return Harness(
            client: client,
            server: server,
            clientEvents: clientEvents,
            serverEvents: serverEvents,
            clientTransport: clientTransport,
            serverTransport: serverTransport
        )
    }

    @Test("both sides authenticate and agree on capabilities")
    func handshakeSucceeds() async {
        let harness = await makeHarness()
        await harness.client.start()
        await harness.server.start()

        let establishedBoth = await pollUntil {
            let clientReady = await harness.clientEvents.established() != nil
            let serverReady = await harness.serverEvents.established() != nil
            return clientReady && serverReady
        }
        #expect(establishedBoth, "both sides must authenticate")

        let clientView = await harness.clientEvents.established()
        let serverView = await harness.serverEvents.established()

        #expect(clientView?.name == "Android")
        #expect(serverView?.name == "Mac")
        #expect(clientView?.negotiated == [.clipboard, .notifications])
        #expect(serverView?.negotiated == [.clipboard, .notifications])
        #expect(clientView?.fingerprint == Fingerprint(spki: Data("server public key".utf8)))
        #expect(serverView?.fingerprint == Fingerprint(spki: Data("client public key".utf8)))
    }

    @Test("a message sent after authentication is delivered")
    func messagesFlow() async {
        let harness = await makeHarness()
        await harness.client.start()
        await harness.server.start()
        _ = await pollUntil { await harness.serverEvents.established() != nil }

        try? await harness.client.send(
            Envelope(type: .clipboardUpdate, body: .object(["text": .string("hello")]))
        )

        let delivered = await pollUntil {
            await harness.serverEvents.message(ofType: .clipboardUpdate) != nil
        }
        #expect(delivered)
        let message = await harness.serverEvents.message(ofType: .clipboardUpdate)
        #expect(message?.bodyField("text")?.stringValue == "hello")
    }

    @Test("sending before authentication is refused")
    func refusesSendBeforeAuthentication() async {
        let harness = await makeHarness()
        // Never started: nothing has been authenticated.
        await #expect(throws: SessionError.notEstablished) {
            try await harness.client.send(Envelope(type: .ping, body: nil))
        }
    }

    @Test("a pairing message on an established session is a protocol violation")
    func rejectsPairingMessageOnSession() async {
        let harness = await makeHarness()
        await harness.client.start()
        await harness.server.start()
        _ = await pollUntil { await harness.serverEvents.established() != nil }

        try? await harness.client.send(Envelope(type: .pairRequest, body: nil))

        let closed = await pollUntil { await harness.serverEvents.closeReason() != nil }
        #expect(closed)
        let reason = await harness.serverEvents.closeReason()
        guard case .protocolViolation(let detail) = reason else {
            Issue.record("expected a protocol violation, got \(String(describing: reason))")
            return
        }
        #expect(detail.contains("pairing"))
    }

    @Test("a message before the handshake fails the session")
    func rejectsEarlyMessage() async {
        let harness = await makeHarness()
        await harness.server.start()

        try? await harness.clientTransport.send(
            try EnvelopeCodec.frame(for: Envelope(type: .clipboardUpdate, body: nil))
        )

        let closed = await pollUntil { await harness.serverEvents.closeReason() != nil }
        #expect(closed)
        let reason = await harness.serverEvents.closeReason()
        guard case .handshakeFailed = reason else {
            Issue.record("expected handshakeFailed, got \(String(describing: reason))")
            return
        }
    }

    @Test("a peer that presents our own device id is refused")
    func rejectsSelfConnection() async {
        let (clientTransport, serverTransport) = FrameTransportLoopback.makePair()
        clientTransport.peerPublicKey = Data("k".utf8)
        serverTransport.peerPublicKey = Data("k".utf8)

        var info = makeDeviceInfo(name: "Twin", platform: .macos, capabilities: [])
        let sameID = info.deviceID
        info.deviceID = sameID

        let client = PeerSession(transport: clientTransport, local: info, role: .initiator)
        let server = PeerSession(transport: serverTransport, local: info, role: .responder)
        let recorder = EventRecorder()
        await recorder.consume(await client.events())
        await client.start()
        await server.start()

        let closed = await pollUntil { await recorder.closeReason() != nil }
        #expect(closed)
        let reason = await recorder.closeReason()
        guard case .handshakeFailed(let detail) = reason else {
            Issue.record("expected handshakeFailed, got \(String(describing: reason))")
            return
        }
        #expect(detail.contains("own identifier"))
    }

    @Test("a peer that stops responding is dropped after the heartbeat timeout")
    func heartbeatTimeout() async {
        // A silent transport: the handshake never completes, so the deadline fires.
        let (clientTransport, _) = FrameTransportLoopback.makePair()
        clientTransport.peerPublicKey = Data("k".utf8)

        let session = PeerSession(
            transport: clientTransport,
            local: makeDeviceInfo(name: "Mac", platform: .macos, capabilities: []),
            role: .initiator,
            heartbeatInterval: .milliseconds(50),
            deadAfter: 0.2,
            handshakeTimeout: .milliseconds(150)
        )
        let recorder = EventRecorder()
        await recorder.consume(await session.events())
        await session.start()

        let closed = await pollUntil(timeout: .seconds(3)) { await recorder.closeReason() != nil }
        #expect(closed, "a silent peer must not hang the session forever")
        let reason = await recorder.closeReason()
        guard case .handshakeFailed = reason else {
            Issue.record("expected handshakeFailed, got \(String(describing: reason))")
            return
        }
    }

    @Test("a ping keeps the session alive and produces no application event")
    func answersPing() async {
        let harness = await makeHarness(heartbeatInterval: .seconds(60))
        await harness.client.start()
        await harness.server.start()
        _ = await pollUntil { await harness.serverEvents.established() != nil }

        try? await harness.client.send(
            Envelope(type: .ping, body: .object(["nonce": .string(Nonce().hex)]))
        )

        // Heartbeats are transport plumbing: they must not surface as application messages,
        // and they must not tear the session down.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await harness.serverEvents.closeReason() == nil)
        #expect(await harness.serverEvents.messages().isEmpty)
        #expect(await harness.serverEvents.established() != nil)
    }

    @Test("an unknown message type is ignored, not fatal")
    func ignoresUnknownMessageType() async {
        let harness = await makeHarness(heartbeatInterval: .seconds(60))
        await harness.client.start()
        await harness.server.start()
        _ = await pollUntil { await harness.serverEvents.established() != nil }

        try? await harness.client.send(
            Envelope(type: .unknown("future.capability"), body: .object(["x": .number(1)]))
        )

        let delivered = await pollUntil {
            await harness.serverEvents.message(ofType: .unknown("future.capability")) != nil
        }
        #expect(delivered, "unknown types are forwarded for the layer above to ignore")
        #expect(await harness.serverEvents.closeReason() == nil)
    }
}
