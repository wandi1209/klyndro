package id.my.wandidev.klyndro.net

import com.google.gson.JsonObject
import id.my.wandidev.klyndro.crypto.Fingerprint
import id.my.wandidev.klyndro.protocol.Capability
import id.my.wandidev.klyndro.protocol.Envelope
import id.my.wandidev.klyndro.protocol.EnvelopeCodec
import id.my.wandidev.klyndro.protocol.MessageType
import id.my.wandidev.klyndro.protocol.Platform
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PeerSessionTest {

    private class Harness(
        val client: PeerSession,
        val server: PeerSession,
        val clientTransport: InMemoryFrameTransport,
        val serverTransport: InMemoryFrameTransport
    )

    private fun harness(
        clientCapabilities: List<Capability> = listOf(
            Capability.CLIPBOARD,
            Capability.MIRRORING,
            Capability.NOTIFICATIONS
        ),
        serverCapabilities: List<Capability> = listOf(Capability.CLIPBOARD, Capability.NOTIFICATIONS),
        heartbeatMillis: Long = 60_000,
        deadAfterMillis: Long = 120_000,
        handshakeTimeoutMillis: Long = 2_000
    ): Harness {
        val (clientTransport, serverTransport) = InMemoryFrameTransport.pair()
        clientTransport.peerFingerprintValue = Fingerprint.ofSpki("server key".toByteArray())
        serverTransport.peerFingerprintValue = Fingerprint.ofSpki("client key".toByteArray())

        val client = PeerSession(
            transport = clientTransport,
            local = localInfo("Mac", Platform.MACOS, clientCapabilities),
            role = PeerSession.Role.INITIATOR,
            heartbeatMillis = heartbeatMillis,
            deadAfterMillis = deadAfterMillis,
            handshakeTimeoutMillis = handshakeTimeoutMillis
        )
        val server = PeerSession(
            transport = serverTransport,
            local = localInfo("Android", Platform.ANDROID, serverCapabilities),
            role = PeerSession.Role.RESPONDER,
            heartbeatMillis = heartbeatMillis,
            deadAfterMillis = deadAfterMillis,
            handshakeTimeoutMillis = handshakeTimeoutMillis
        )
        return Harness(client, server, clientTransport, serverTransport)
    }

    private fun unknownTypeEnvelope(): Envelope = Envelope(
        v = Envelope.CURRENT_VERSION,
        id = java.util.UUID.randomUUID().toString().lowercase(),
        type = "future.capability",
        ts = System.currentTimeMillis(),
        body = JsonObject().apply { addProperty("x", 1) }
    )

    @Test
    fun `both sides authenticate and agree on capabilities`() = runBlocking {
        coroutineScope {
            val harness = harness()
            val clientRecorder = SessionRecorder(this, harness.client.events())
            val serverRecorder = SessionRecorder(this, harness.server.events())
            val clientJob = launch { harness.client.run() }
            val serverJob = launch { harness.server.run() }

            val clientView = clientRecorder.established()
            val serverView = serverRecorder.established()

            assertNotNull("both sides must authenticate", clientView)
            assertNotNull(serverView)
            assertEquals("Android", clientView!!.name)
            assertEquals("Mac", serverView!!.name)
            assertEquals(listOf(Capability.CLIPBOARD, Capability.NOTIFICATIONS), clientView.negotiated)
            assertTrue(clientView.fingerprint.matches(Fingerprint.ofSpki("server key".toByteArray())))
            assertTrue(serverView.fingerprint.matches(Fingerprint.ofSpki("client key".toByteArray())))

            clientJob.cancelAndJoin()
            serverJob.cancelAndJoin()
        }
    }

    @Test
    fun `a message sent after authentication is delivered`() = runBlocking {
        coroutineScope {
            val harness = harness()
            val serverRecorder = SessionRecorder(this, harness.server.events())
            val clientJob = launch { harness.client.run() }
            val serverJob = launch { harness.server.run() }

            assertNotNull(serverRecorder.established())
            harness.client.send(
                envelope(MessageType.CLIPBOARD_UPDATE, JsonObject().apply { addProperty("text", "hello") })
            )

            val received = withTimeout(5_000) {
                while (serverRecorder.messages().none { it.messageType == MessageType.CLIPBOARD_UPDATE }) {
                    delay(10)
                }
                serverRecorder.messages().first { it.messageType == MessageType.CLIPBOARD_UPDATE }
            }
            assertEquals("hello", received.body!!.get("text").asString)

            clientJob.cancelAndJoin()
            serverJob.cancelAndJoin()
        }
    }

    @Test
    fun `sending before authentication is refused`() = runBlocking {
        val harness = harness()
        val error = runCatching { harness.client.send(envelope(MessageType.PING)) }.exceptionOrNull()
        assertTrue("expected a refusal, got $error", error is IllegalStateException)
    }

    @Test
    fun `a pairing message on an established session is a protocol violation`() = runBlocking {
        coroutineScope {
            val harness = harness()
            val serverRecorder = SessionRecorder(this, harness.server.events())
            val clientJob = launch { harness.client.run() }
            val serverJob = launch { harness.server.run() }

            assertNotNull(serverRecorder.established())
            harness.client.send(envelope(MessageType.PAIR_REQUEST))

            val reason = serverRecorder.closeReason()
            assertTrue("expected a protocol violation, got $reason", reason is SessionCloseReason.ProtocolViolation)
            assertTrue((reason as SessionCloseReason.ProtocolViolation).detail.contains("pairing"))

            clientJob.cancelAndJoin()
            serverJob.cancelAndJoin()
        }
    }

    @Test
    fun `a message before the handshake fails the session`() = runBlocking {
        coroutineScope {
            val harness = harness()
            val serverRecorder = SessionRecorder(this, harness.server.events())
            val serverJob = launch { harness.server.run() }

            harness.clientTransport.send(
                EnvelopeCodec.frameFor(envelope(MessageType.CLIPBOARD_UPDATE))
            )

            val reason = serverRecorder.closeReason()
            assertTrue("expected a handshake failure, got $reason", reason is SessionCloseReason.HandshakeFailed)

            serverJob.cancelAndJoin()
        }
    }

    @Test
    fun `an unknown message type is forwarded, not fatal`() = runBlocking {
        coroutineScope {
            val harness = harness()
            val serverRecorder = SessionRecorder(this, harness.server.events())
            val clientJob = launch { harness.client.run() }
            val serverJob = launch { harness.server.run() }

            assertNotNull(serverRecorder.established())
            harness.client.send(unknownTypeEnvelope())

            val forwarded = serverRecorder.awaitEvent { it is PeerSessionEvent.Message }
            assertTrue(forwarded is PeerSessionEvent.Message)
            assertNull(serverRecorder.closeReason())

            clientJob.cancelAndJoin()
            serverJob.cancelAndJoin()
        }
    }

    @Test
    fun `a silent peer does not hang the handshake`() = runBlocking {
        coroutineScope {
            val (clientTransport, _) = InMemoryFrameTransport.pair()
            clientTransport.peerFingerprintValue = Fingerprint.ofSpki("k".toByteArray())
            val session = PeerSession(
                transport = clientTransport,
                local = localInfo("Mac", Platform.MACOS, emptyList()),
                role = PeerSession.Role.INITIATOR,
                handshakeTimeoutMillis = 150
            )
            val recorder = SessionRecorder(this, session.events())
            val job = launch { session.run() }

            val reason = recorder.closeReason()
            assertTrue("expected a handshake failure, got $reason", reason is SessionCloseReason.HandshakeFailed)
            job.cancelAndJoin()
        }
    }
}
