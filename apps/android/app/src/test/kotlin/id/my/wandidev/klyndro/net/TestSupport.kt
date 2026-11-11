package id.my.wandidev.klyndro.net

import id.my.wandidev.klyndro.crypto.Fingerprint
import id.my.wandidev.klyndro.crypto.Nonce
import id.my.wandidev.klyndro.protocol.Capability
import id.my.wandidev.klyndro.protocol.DeviceId
import id.my.wandidev.klyndro.protocol.Envelope
import id.my.wandidev.klyndro.protocol.MessageType
import id.my.wandidev.klyndro.protocol.Platform
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.concurrent.CopyOnWriteArrayList

/** Collects session events so tests can assert without racing the channel. */
class SessionRecorder(scope: CoroutineScope, events: kotlinx.coroutines.channels.ReceiveChannel<PeerSessionEvent>) {
    val received = CopyOnWriteArrayList<PeerSessionEvent>()

    init {
        scope.launch {
            for (event in events) received.add(event)
        }
    }

    suspend fun awaitEvent(
        timeoutMillis: Long = 5_000,
        predicate: (PeerSessionEvent) -> Boolean
    ): PeerSessionEvent? {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            received.firstOrNull(predicate)?.let { return it }
            delay(10)
        }
        return received.firstOrNull(predicate)
    }

    suspend fun established(): PeerSessionInfo? {
        val event = awaitEvent { it is PeerSessionEvent.Established }
        return (event as? PeerSessionEvent.Established)?.info
    }

    suspend fun closeReason(): SessionCloseReason? {
        val event = awaitEvent { it is PeerSessionEvent.Closed }
        return (event as? PeerSessionEvent.Closed)?.reason
    }

    fun messages(): List<Envelope> = received.mapNotNull { (it as? PeerSessionEvent.Message)?.envelope }
}

fun localInfo(
    name: String,
    platform: Platform,
    capabilities: List<Capability>
): LocalDeviceInfo = LocalDeviceInfo(
    deviceId = DeviceId.random(),
    name = name,
    platform = platform,
    appVersion = "0.1.0-test",
    capabilities = capabilities,
    fingerprint = Fingerprint.ofSpki(name.toByteArray())
)

fun envelope(type: MessageType, body: com.google.gson.JsonObject? = null): Envelope = Envelope(
    v = Envelope.CURRENT_VERSION,
    id = java.util.UUID.randomUUID().toString().lowercase(),
    type = requireNotNull(type.wireName),
    ts = System.currentTimeMillis(),
    body = body
)

fun nonceHex(): String = Nonce.random().hex
