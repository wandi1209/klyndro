package id.my.wandidev.klyndro.net

import id.my.wandidev.klyndro.crypto.Fingerprint
import id.my.wandidev.klyndro.crypto.Nonce
import id.my.wandidev.klyndro.protocol.Capability
import id.my.wandidev.klyndro.protocol.DeviceId
import id.my.wandidev.klyndro.protocol.Envelope
import id.my.wandidev.klyndro.protocol.EnvelopeCodec
import id.my.wandidev.klyndro.protocol.HandshakeCodec
import id.my.wandidev.klyndro.protocol.HandshakeException
import id.my.wandidev.klyndro.protocol.HelloBody
import id.my.wandidev.klyndro.protocol.MessageType
import id.my.wandidev.klyndro.protocol.PairingMessageException
import id.my.wandidev.klyndro.protocol.Platform
import id.my.wandidev.klyndro.protocol.ProtocolException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel

/** What this device advertises about itself in `hello`. */
data class LocalDeviceInfo(
    val deviceId: DeviceId,
    val name: String,
    val platform: Platform,
    val appVersion: String,
    val capabilities: List<Capability>,
    val fingerprint: Fingerprint
) {
    fun helloBody(nonce: String): HelloBody = HelloBody(
        deviceId = deviceId,
        deviceName = name,
        platform = platform,
        appVersion = appVersion,
        protocolVersion = Envelope.CURRENT_VERSION,
        capabilities = capabilities,
        nonce = nonce
    )
}

/** The authenticated peer, as established by the handshake. */
data class PeerSessionInfo(
    val deviceId: DeviceId,
    val name: String,
    val platform: Platform,
    val appVersion: String,
    val capabilities: List<Capability>,
    /** Fingerprint observed from the peer's TLS certificate, not from its claims. */
    val fingerprint: Fingerprint,
    /** Capabilities both sides support. */
    val negotiated: List<Capability>
)

sealed interface PeerSessionEvent {
    data class Established(val info: PeerSessionInfo) : PeerSessionEvent
    data class Message(val envelope: Envelope) : PeerSessionEvent
    data class Closed(val reason: SessionCloseReason) : PeerSessionEvent
}

sealed interface SessionCloseReason {
    data object Local : SessionCloseReason
    data object Peer : SessionCloseReason
    data object HeartbeatTimeout : SessionCloseReason
    data class HandshakeFailed(val detail: String) : SessionCloseReason
    data class ProtocolViolation(val detail: String) : SessionCloseReason
    data class TransportFailed(val detail: String) : SessionCloseReason
}

sealed class SessionException(message: String) : Exception(message) {
    data object NotEstablished : SessionException("session is not authenticated")
    data object SelfConnection : SessionException("peer presented this device's own identifier")
    data class UnexpectedMessageBeforeHandshake(val type: MessageType) :
        SessionException("received ${type.wireName} before handshake")

    data class PeerReportedError(val code: String) : SessionException("peer reported $code")
    data object PeerKeyUnavailable : SessionException("the transport did not expose the peer key")
    data object HandshakeTimedOut : SessionException("the handshake timed out")
}

/**
 * Owns one authenticated session: handshake, heartbeat, and message dispatch.
 *
 * Transport-agnostic: driven by [SocketFrameTransport] in the app and by in-memory transports in
 * tests, which is where the timing and violation rules are proven. Mirrors the Swift
 * `PeerSession`.
 */
class PeerSession(
    private val transport: FrameTransport,
    private val local: LocalDeviceInfo,
    private val role: Role,
    private val heartbeatMillis: Long = 15_000,
    private val deadAfterMillis: Long = 45_000,
    private val handshakeTimeoutMillis: Long = 10_000
) {
    enum class Role { INITIATOR, RESPONDER }

    private val eventChannel = Channel<PeerSessionEvent>(Channel.UNLIMITED)

    @Volatile
    private var established = false

    @Volatile
    private var lastActivity = System.currentTimeMillis()

    fun events(): ReceiveChannel<PeerSessionEvent> = eventChannel

    suspend fun send(envelope: Envelope) {
        check(established) { SessionException.NotEstablished.message ?: "not authenticated" }
        transport.send(EnvelopeCodec.frameFor(envelope))
    }

    fun close() {
        transport.close()
    }

    /** Drives the session until the peer closes, a violation occurs, or the caller cancels. */
    suspend fun run() = coroutineScope {
        var heartbeat: Job? = null
        var recorded: SessionCloseReason? = null

        try {
            val info = withTimeoutOrNull(handshakeTimeoutMillis) { performHandshake() }
                ?: throw SessionException.HandshakeTimedOut

            established = true
            eventChannel.send(PeerSessionEvent.Established(info))
            heartbeat = launch { heartbeatLoop() }

            loop@ while (true) {
                val frame = transport.receive() ?: break
                lastActivity = System.currentTimeMillis()
                val envelope = EnvelopeCodec.decode(frame)

                when (envelope.messageType) {
                    MessageType.PING -> {
                        val nonce = envelope.body?.get("nonce")?.asString ?: ""
                        runCatching {
                            transport.send(
                                EnvelopeCodec.frameFor(
                                    Envelope(
                                        v = Envelope.CURRENT_VERSION,
                                        id = java.util.UUID.randomUUID().toString().lowercase(),
                                        type = MessageType.PONG.wireName!!,
                                        ts = System.currentTimeMillis(),
                                        body = com.google.gson.JsonObject().apply {
                                            addProperty("nonce", nonce)
                                        }
                                    )
                                )
                            )
                        }
                    }

                    MessageType.PONG -> Unit

                    MessageType.PAIR_REQUEST,
                    MessageType.PAIR_CONFIRM,
                    MessageType.PAIR_RESULT -> {
                        recorded = SessionCloseReason.ProtocolViolation(
                            "pairing message on an authenticated session"
                        )
                        break@loop
                    }

                    MessageType.HELLO, MessageType.HELLO_ACK -> {
                        recorded = SessionCloseReason.ProtocolViolation(
                            "handshake restart on an established session"
                        )
                        break@loop
                    }

                    else -> eventChannel.send(PeerSessionEvent.Message(envelope))
                }
            }

            if (recorded == null) recorded = SessionCloseReason.Peer
        } catch (cancellation: CancellationException) {
            recorded = SessionCloseReason.Local
            throw cancellation
        } catch (error: SessionException) {
            recorded = SessionCloseReason.HandshakeFailed(error.message ?: "handshake failed")
        } catch (error: ProtocolException) {
            recorded = SessionCloseReason.ProtocolViolation(error.message ?: "protocol violation")
        } catch (error: HandshakeException) {
            recorded = SessionCloseReason.HandshakeFailed(error.message ?: "handshake failed")
        } catch (error: PairingMessageException) {
            recorded = SessionCloseReason.ProtocolViolation(error.message ?: "protocol violation")
        } catch (error: IllegalStateException) {
            recorded = SessionCloseReason.TransportFailed(error.message ?: "transport failed")
        } catch (error: Exception) {
            recorded = SessionCloseReason.TransportFailed(error.message ?: "transport failed")
        } finally {
            heartbeat?.cancel()
            established = false
            transport.close()
            eventChannel.send(PeerSessionEvent.Closed(recorded ?: SessionCloseReason.Peer))
            eventChannel.close()
        }
    }

    private suspend fun performHandshake(): PeerSessionInfo {
        val localNonce = Nonce.random()
        var remoteHello: HelloBody? = null
        var ackSent = false
        var ackReceived = false

        transport.send(EnvelopeCodec.frameFor(helloEnvelope(localNonce)))

        while (remoteHello == null || (role == Role.INITIATOR && !ackReceived) ||
            (role == Role.RESPONDER && !ackSent)
        ) {
            val frame = transport.receive()
                ?: throw SessionException.HandshakeTimedOut
            val envelope = EnvelopeCodec.decode(frame)

            when (envelope.messageType) {
                MessageType.HELLO -> {
                    val hello = HandshakeCodec.decodeHello(envelope)
                    if (hello.deviceId == local.deviceId) throw SessionException.SelfConnection
                    remoteHello = hello

                    if (role == Role.RESPONDER && !ackSent) {
                        val ackNonce = Nonce.random()
                        val ackBody = local.helloBody(ackNonce.hex).toAckJson(hello.nonce)
                        transport.send(
                            EnvelopeCodec.frameFor(
                                Envelope(
                                    v = Envelope.CURRENT_VERSION,
                                    id = java.util.UUID.randomUUID().toString().lowercase(),
                                    type = MessageType.HELLO_ACK.wireName!!,
                                    ts = System.currentTimeMillis(),
                                    body = ackBody
                                )
                            )
                        )
                        ackSent = true
                    }
                }

                MessageType.HELLO_ACK -> {
                    val (hello, echo) = HandshakeCodec.decodeHelloAck(envelope)
                    if (remoteHello == null) {
                        if (hello.deviceId == local.deviceId) throw SessionException.SelfConnection
                        remoteHello = hello
                    }
                    HandshakeCodec.verifyEcho(echo, localNonce.hex)
                    ackReceived = true
                }

                MessageType.ERROR -> throw SessionException.PeerReportedError(
                    envelope.body?.get("code")?.asString ?: "unknown"
                )

                else -> throw SessionException.UnexpectedMessageBeforeHandshake(envelope.messageType)
            }
        }

        val remote = remoteHello ?: throw SessionException.HandshakeTimedOut
        val fingerprint = transport.peerFingerprint() ?: throw SessionException.PeerKeyUnavailable

        return PeerSessionInfo(
            deviceId = remote.deviceId,
            name = remote.deviceName,
            platform = remote.platform,
            appVersion = remote.appVersion,
            capabilities = remote.capabilities,
            fingerprint = fingerprint,
            negotiated = Capability.negotiate(local.capabilities, remote.capabilities)
        )
    }

    private fun helloEnvelope(nonce: Nonce): Envelope = Envelope(
        v = Envelope.CURRENT_VERSION,
        id = java.util.UUID.randomUUID().toString().lowercase(),
        type = MessageType.HELLO.wireName!!,
        ts = System.currentTimeMillis(),
        body = local.helloBody(nonce.hex).toJson()
    )

    private suspend fun heartbeatLoop() {
        while (currentCoroutineIsActive()) {
            delay(heartbeatMillis)
            if (!currentCoroutineIsActive()) return

            if (System.currentTimeMillis() - lastActivity > deadAfterMillis) {
                transport.close()
                return
            }

            runCatching {
                transport.send(
                    EnvelopeCodec.frameFor(
                        Envelope(
                            v = Envelope.CURRENT_VERSION,
                            id = java.util.UUID.randomUUID().toString().lowercase(),
                            type = MessageType.PING.wireName!!,
                            ts = System.currentTimeMillis(),
                            body = com.google.gson.JsonObject().apply {
                                addProperty("nonce", Nonce.random().hex)
                            }
                        )
                    )
                )
            }
        }
    }

    private suspend fun currentCoroutineIsActive(): Boolean =
        kotlinx.coroutines.currentCoroutineContext()[Job]?.isActive ?: false
}
