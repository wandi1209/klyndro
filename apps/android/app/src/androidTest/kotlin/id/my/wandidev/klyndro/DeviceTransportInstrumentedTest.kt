package id.my.wandidev.klyndro

import androidx.test.ext.junit.runners.AndroidJUnit4
import id.my.wandidev.klyndro.crypto.DeviceIdentity
import id.my.wandidev.klyndro.crypto.Fingerprint
import id.my.wandidev.klyndro.net.LocalDeviceInfo
import id.my.wandidev.klyndro.net.PeerSession
import id.my.wandidev.klyndro.net.PeerSessionEvent
import id.my.wandidev.klyndro.net.PinPolicy
import id.my.wandidev.klyndro.net.TlsClient
import id.my.wandidev.klyndro.net.TlsServer
import id.my.wandidev.klyndro.protocol.Capability
import id.my.wandidev.klyndro.protocol.DeviceId
import id.my.wandidev.klyndro.protocol.Platform
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Real TLS 1.3 on the device's own loopback interface, using the device's JSSE and BouncyCastle
 * providers. The JVM suite covers the same code path, but only this run proves it works with the
 * Android security provider and the runtime's TLS stack.
 */
@RunWith(AndroidJUnit4::class)
class DeviceTransportInstrumentedTest {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @After
    fun tearDown() {
        scope.cancel()
    }

    private fun info(name: String, platform: Platform, capabilities: List<Capability>) =
        LocalDeviceInfo(
            deviceId = DeviceId.random(),
            name = name,
            platform = platform,
            appVersion = "0.1.0-androidTest",
            capabilities = capabilities,
            fingerprint = Fingerprint.ofSpki(name.toByteArray())
        )

    private suspend fun ReceiveChannel<PeerSessionEvent>.awaitEstablished(timeoutMs: Long = 10_000) =
        withTimeout(timeoutMs) {
            for (event in this@awaitEstablished) {
                if (event is PeerSessionEvent.Established) return@withTimeout event.info
                if (event is PeerSessionEvent.Closed) return@withTimeout null
            }
            null
        }

    @Test
    fun mutualTlsWithPinnedKeysAuthenticatesBothSidesOnDevice() = runBlocking {
        val serverIdentity = DeviceIdentity.createSelfSigned("Device Server", DeviceIdentity.generateKeyPair())
        val clientIdentity = DeviceIdentity.createSelfSigned("Device Client", DeviceIdentity.generateKeyPair())

        val serverEvents = CopyOnWriteArrayList<PeerSessionEvent>()
        var serverConnections = 0

        val server = TlsServer(
            identity = serverIdentity,
            policy = PinPolicy.pinned(setOf(clientIdentity.fingerprint))
        ) { transport ->
            serverConnections++
            val session = PeerSession(
                transport = transport,
                local = info("Device Android", Platform.ANDROID, listOf(Capability.CLIPBOARD)),
                role = PeerSession.Role.RESPONDER
            )
            scope.launch {
                for (event in session.events()) serverEvents.add(event)
            }
            scope.launch { session.run() }
        }

        try {
            server.start(scope)

            val transport = TlsClient.connect(
                host = "127.0.0.1",
                port = server.port,
                identity = clientIdentity,
                policy = PinPolicy.pinned(setOf(serverIdentity.fingerprint)),
                scope = scope
            )
            val clientSession = PeerSession(
                transport = transport,
                local = info("Device Mac", Platform.MACOS, listOf(Capability.CLIPBOARD, Capability.MIRRORING)),
                role = PeerSession.Role.INITIATOR
            )
            val clientJob = scope.launch { clientSession.run() }
            val clientInfo = clientSession.events().awaitEstablished()

            assertNotNull("the initiator must authenticate over on-device TLS", clientInfo)
            assertTrue(clientInfo!!.fingerprint.matches(serverIdentity.fingerprint))
            assertTrue(clientInfo.negotiated == listOf(Capability.CLIPBOARD))

            // Both sides authenticated: the responder also saw the client's certificate.
            val serverInfo = withTimeout(10_000) {
                while (serverEvents.none { it is PeerSessionEvent.Established }) {
                    kotlinx.coroutines.delay(20)
                }
                (serverEvents.first { it is PeerSessionEvent.Established } as PeerSessionEvent.Established).info
            }
            assertTrue(serverInfo.fingerprint.matches(clientIdentity.fingerprint))
            assertTrue(serverConnections >= 1)

            clientJob.cancel()
        } finally {
            server.close()
        }
    }

    @Test
    fun untrustedCertificateIsRefusedOnDevice() = runBlocking {
        val serverIdentity = DeviceIdentity.createSelfSigned("Strict Server", DeviceIdentity.generateKeyPair())
        val clientIdentity = DeviceIdentity.createSelfSigned("Unvetted Client", DeviceIdentity.generateKeyPair())

        val server = TlsServer(
            identity = serverIdentity,
            policy = PinPolicy.pinned(setOf(Fingerprint.ofSpki("someone else".toByteArray())))
        ) { transport ->
            val session = PeerSession(
                transport = transport,
                local = info("Strict Android", Platform.ANDROID, emptyList()),
                role = PeerSession.Role.RESPONDER
            )
            scope.launch { session.run() }
        }

        try {
            server.start(scope)

            val transport = runCatching {
                TlsClient.connect(
                    host = "127.0.0.1",
                    port = server.port,
                    identity = clientIdentity,
                    policy = PinPolicy.pinned(setOf(serverIdentity.fingerprint)),
                    scope = scope
                )
            }.getOrNull()

            // Rejected during the handshake is fine. What must never happen is a session.
            if (transport != null) {
                val session = PeerSession(
                    transport = transport,
                    local = info("Unvetted Mac", Platform.MACOS, emptyList()),
                    role = PeerSession.Role.INITIATOR
                )
                scope.launch { session.run() }
                val info = session.events().awaitEstablished()
                assertNull("an untrusted peer must never authenticate", info)
            }
        } finally {
            server.close()
        }
    }
}
