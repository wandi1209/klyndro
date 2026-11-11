package id.my.wandidev.klyndro.net

import id.my.wandidev.klyndro.crypto.DeviceIdentity
import id.my.wandidev.klyndro.crypto.Fingerprint
import id.my.wandidev.klyndro.protocol.Capability
import id.my.wandidev.klyndro.protocol.Platform
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * End-to-end TLS 1.3 on the loopback interface with real certificates and real pinning decisions.
 *
 * JSSE is plain Java, so this runs as a JVM unit test: it is the strongest evidence available for
 * the Android transport without a device attached.
 */
class TlsLoopbackTest {

    private fun identity(name: String) =
        DeviceIdentity.createSelfSigned(name, DeviceIdentity.generateKeyPair())

    @Test
    fun `mutual TLS with pinned keys authenticates both sides`() = runBlocking {
        coroutineScope {
            val serverIdentity = identity("Loopback Server")
            val clientIdentity = identity("Loopback Client")

            val serverSession = AtomicReference<PeerSession>()
            val serverRecorder = AtomicReference<SessionRecorder>()

            val server = TlsServer(
                identity = serverIdentity,
                policy = PinPolicy.pinned(setOf(clientIdentity.fingerprint))
            ) { transport ->
                val session = PeerSession(
                    transport = transport,
                    local = localInfo("Loopback Android", Platform.ANDROID, listOf(Capability.CLIPBOARD)),
                    role = PeerSession.Role.RESPONDER
                )
                serverSession.set(session)
                serverRecorder.set(SessionRecorder(this, session.events()))
                launch { session.run() }
            }
            server.use {
                server.start(this)

                val clientTransport = TlsClient.connect(
                    host = "127.0.0.1",
                    port = server.port,
                    identity = clientIdentity,
                    policy = PinPolicy.pinned(setOf(serverIdentity.fingerprint)),
                    scope = this
                )
                val clientSession = PeerSession(
                    transport = clientTransport,
                    local = localInfo("Loopback Mac", Platform.MACOS, listOf(Capability.CLIPBOARD, Capability.MIRRORING)),
                    role = PeerSession.Role.INITIATOR
                )
                val clientRecorder = SessionRecorder(this, clientSession.events())
                val clientJob = launch { clientSession.run() }

                val clientView = clientRecorder.established()
                assertNotNull("the initiator must authenticate", clientView)

                // The claimed identity and the certificate seen by TLS must agree.
                assertTrue(clientView!!.fingerprint.matches(serverIdentity.fingerprint))
                assertTrue(clientView.negotiated == listOf(Capability.CLIPBOARD))

                // The server side must also have authenticated, and seen the client's key.
                val serverView = serverRecorder.get()?.established()
                assertNotNull("the responder must authenticate", serverView)
                assertTrue(serverView!!.fingerprint.matches(clientIdentity.fingerprint))

                clientJob.cancelAndJoin()
            }
        }
    }

    @Test
    fun `a peer with an untrusted certificate never authenticates`() = runBlocking {
        coroutineScope {
            val serverIdentity = identity("Strict Server")
            val clientIdentity = identity("Unvetted Client")

            val server = TlsServer(
                identity = serverIdentity,
                policy = PinPolicy.pinned(setOf(Fingerprint.ofSpki("someone else".toByteArray())))
            ) { transport ->
                val session = PeerSession(
                    transport = transport,
                    local = localInfo("Strict Android", Platform.ANDROID, emptyList()),
                    role = PeerSession.Role.RESPONDER
                )
                launch { session.run() }
            }

            server.use {
                server.start(this)

                val transport = runCatching {
                    TlsClient.connect(
                        host = "127.0.0.1",
                        port = server.port,
                        identity = clientIdentity,
                        policy = PinPolicy.pinned(setOf(serverIdentity.fingerprint)),
                        scope = this
                    )
                }.getOrNull()

                // Rejected during the TLS handshake is acceptable. What must never happen is an
                // authenticated session.
                if (transport != null) {
                    val session = PeerSession(
                        transport = transport,
                        local = localInfo("Unvetted Mac", Platform.MACOS, emptyList()),
                        role = PeerSession.Role.INITIATOR
                    )
                    val recorder = SessionRecorder(this, session.events())
                    val job = launch { session.run() }
                    val reason = recorder.closeReason()
                    assertNotNull("an untrusted client must not hang", reason)
                    assertTrue(recorder.established() == null)
                    job.cancelAndJoin()
                }
            }
        }
    }

    @Test
    fun `the pairing window accepts a certificate that is not pinned`() = runBlocking {
        coroutineScope {
            val serverIdentity = identity("Pairing Server")
            val newPhone = identity("New Phone")

            val sessionEstablished = AtomicReference<PeerSessionInfo?>()
            val server = TlsServer(identity = serverIdentity, policy = PinPolicy.PAIRING_ONLY) { transport ->
                val session = PeerSession(
                    transport = transport,
                    local = localInfo("Pairing Android", Platform.ANDROID, emptyList()),
                    role = PeerSession.Role.RESPONDER
                )
                launch { session.run() }
            }

            server.use {
                server.start(this)
                val transport = TlsClient.connect(
                    host = "127.0.0.1",
                    port = server.port,
                    identity = newPhone,
                    policy = PinPolicy.PAIRING_ONLY,
                    scope = this
                )
                val session = PeerSession(
                    transport = transport,
                    local = localInfo("Pairing Mac", Platform.MACOS, emptyList()),
                    role = PeerSession.Role.INITIATOR
                )
                val recorder = SessionRecorder(this, session.events())
                val job = launch { session.run() }

                sessionEstablished.set(recorder.established())
                assertNotNull("a pairing window must allow a first contact", sessionEstablished.get())
                assertTrue(sessionEstablished.get()!!.fingerprint.matches(serverIdentity.fingerprint))

                job.cancelAndJoin()
            }
        }
    }
}
