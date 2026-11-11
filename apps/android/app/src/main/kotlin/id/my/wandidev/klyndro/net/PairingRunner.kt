package id.my.wandidev.klyndro.net

import id.my.wandidev.klyndro.crypto.Fingerprint
import id.my.wandidev.klyndro.crypto.Nonce
import id.my.wandidev.klyndro.crypto.PairingAttempt
import id.my.wandidev.klyndro.crypto.PairingCode
import id.my.wandidev.klyndro.crypto.PairingValidationException
import id.my.wandidev.klyndro.crypto.PairingWindow
import id.my.wandidev.klyndro.crypto.PairingWindowException
import id.my.wandidev.klyndro.crypto.TrustStore
import id.my.wandidev.klyndro.crypto.TrustedPeer
import id.my.wandidev.klyndro.protocol.Capability
import id.my.wandidev.klyndro.protocol.Envelope
import id.my.wandidev.klyndro.protocol.EnvelopeCodec
import id.my.wandidev.klyndro.protocol.MessageType
import id.my.wandidev.klyndro.protocol.PairConfirmBody
import id.my.wandidev.klyndro.protocol.PairRequestBody
import id.my.wandidev.klyndro.protocol.PairResultBody
import id.my.wandidev.klyndro.protocol.PairingFailure
import id.my.wandidev.klyndro.protocol.PairingMessageCodec
import id.my.wandidev.klyndro.protocol.Platform
import android.util.Log
import kotlinx.coroutines.channels.Channel
import java.util.UUID

/** What this device contributes to a pairing attempt. */
data class PairingLocalInfo(
    val deviceId: id.my.wandidev.klyndro.protocol.DeviceId,
    val name: String,
    val platform: Platform,
    val capabilities: List<Capability>,
    val fingerprint: Fingerprint
) {
    fun request(nonce: Nonce): PairRequestBody = PairRequestBody(
        deviceId = deviceId,
        deviceName = name,
        platform = platform,
        fingerprint = fingerprint,
        nonce = nonce,
        protocolVersion = Envelope.CURRENT_VERSION,
        capabilities = capabilities
    )
}

sealed interface PairingEvent {
    data class AwaitingConfirmation(val code: String, val peerName: String) : PairingEvent
    data class Paired(val peer: TrustedPeer) : PairingEvent
    data class Failed(val reason: PairingFailure) : PairingEvent
}

/**
 * Runs one pairing attempt over an already-established TLS connection.
 *
 * The peer's *claimed* fingerprint is never trusted on its own: it is compared with the key the
 * TLS layer observed for this connection, so a device cannot claim somebody else's identity.
 * Mirrors the Swift `PairingRunner`.
 */
class PairingRunner(
    // Tag for failure logs; nothing sensitive is ever logged (protocol §11).
    private val transport: FrameTransport,
    private val local: PairingLocalInfo,
    private val role: PeerSession.Role,
    private val trustStore: TrustStore,
    private val window: PairingWindow,
    private val peerHost: String? = null,
    private val peerPort: Int? = null
) {
    private val localNonce = Nonce.random()
    private val events = Channel<PairingEvent>(Channel.UNLIMITED)

    @Volatile private var attempt: PairingAttempt? = null
    @Volatile private var peerFingerprintFromTls: Fingerprint? = null
    @Volatile private var confirmedLocally = false
    @Volatile private var peerConfirmed = false
    @Volatile private var finished = false

    fun events(): kotlinx.coroutines.channels.ReceiveChannel<PairingEvent> = events

    suspend fun run() {
        try {
            if (!window.isOpen()) {
                Log.w(TAG, "pairing aborted: window closed before starting")
                finish(PairingEvent.Failed(PairingFailure.WINDOW_CLOSED), null)
                return
            }

            peerFingerprintFromTls = transport.peerFingerprint()
            if (peerFingerprintFromTls == null) {
                Log.w(TAG, "pairing aborted: transport did not expose the peer key")
                finish(PairingEvent.Failed(PairingFailure.INTERNAL), null)
                return
            }

            if (role == PeerSession.Role.INITIATOR) {
                sendRequest()
            }

            while (true) {
                val frame = transport.receive() ?: break
                val envelope = EnvelopeCodec.decode(frame)

                when (envelope.messageType) {
                    MessageType.PAIR_REQUEST -> handleRequest(PairingMessageCodec.decodeRequest(envelope))
                    MessageType.PAIR_CONFIRM -> handleConfirm(PairingMessageCodec.decodeConfirm(envelope))
                    MessageType.PAIR_RESULT -> {
                        val result = PairingMessageCodec.decodeResult(envelope)
                        if (!result.accepted) {
                            finish(
                                PairingEvent.Failed(result.reason ?: PairingFailure.INTERNAL),
                                null
                            )
                        }
                    }
                    else -> finish(PairingEvent.Failed(PairingFailure.INTERNAL), null)
                }
                if (finished) break
            }

            if (!finished) {
                finish(PairingEvent.Failed(PairingFailure.WINDOW_CLOSED), null)
            }
        } catch (error: PairingValidationException) {
            Log.w(TAG, "pairing rejected by validation", error)
            finish(PairingEvent.Failed(PairingFailure.SAS_MISMATCH), PairResultBody(false, PairingFailure.SAS_MISMATCH))
        } catch (error: PairingWindowException) {
            Log.w(TAG, "pairing window problem", error)
            finish(PairingEvent.Failed(PairingFailure.WINDOW_CLOSED), PairResultBody(false, PairingFailure.WINDOW_CLOSED))
        } catch (error: Exception) {
            Log.w(TAG, "pairing failed", error)
            finish(PairingEvent.Failed(PairingFailure.INTERNAL), null)
        }
    }

    /** The user on this device accepted the digits. */
    suspend fun confirm() {
        val current = attempt ?: return
        if (finished) return
        confirmedLocally = true
        runCatching { send(MessageType.PAIR_CONFIRM, current.confirmBody().toJson()) }
        if (peerConfirmed) persistAndFinish(current)
    }

    /** The user on this device rejected the digits. */
    suspend fun reject() {
        if (finished) return
        finish(
            PairingEvent.Failed(PairingFailure.USER_REJECTED),
            PairResultBody(false, PairingFailure.USER_REJECTED)
        )
    }

    private suspend fun handleRequest(request: PairRequestBody) {
        // The claimed fingerprint must match the key TLS observed for this connection.
        val tlsFingerprint = peerFingerprintFromTls
        if (tlsFingerprint == null || !request.fingerprint.matches(tlsFingerprint)) {
            finish(PairingEvent.Failed(PairingFailure.SAS_MISMATCH), PairResultBody(false, PairingFailure.SAS_MISMATCH))
            return
        }

        if (role == PeerSession.Role.RESPONDER) sendRequest()
        if (attempt != null) return

        if (!window.isOpen()) {
            finish(PairingEvent.Failed(PairingFailure.WINDOW_CLOSED), PairResultBody(false, PairingFailure.WINDOW_CLOSED))
            return
        }

        val newAttempt = PairingAttempt(request, local.fingerprint, localNonce)
        attempt = newAttempt
        events.trySend(PairingEvent.AwaitingConfirmation(newAttempt.code.digits, request.deviceName))
    }

    private suspend fun handleConfirm(confirm: PairConfirmBody) {
        val current = attempt
        if (current == null) {
            finish(PairingEvent.Failed(PairingFailure.INTERNAL), null)
            return
        }

        try {
            current.validate(confirm)
        } catch (_: PairingValidationException) {
            finish(PairingEvent.Failed(PairingFailure.SAS_MISMATCH), PairResultBody(false, PairingFailure.SAS_MISMATCH))
            return
        }

        peerConfirmed = true
        // Both sides must have shown the code to a human before anything is persisted.
        if (!confirmedLocally) return

        persistAndFinish(current)
    }

    private suspend fun persistAndFinish(current: PairingAttempt) {
        val peer = current.trustedPeer(peerHost, peerPort)
        runCatching { trustStore.upsert(peer) }
            .onFailure { error ->
                Log.w(TAG, "could not persist the paired device", error)
                finish(PairingEvent.Failed(PairingFailure.INTERNAL), null)
                return
            }

        runCatching { send(MessageType.PAIR_RESULT, PairResultBody(true).toJson()) }
        finish(PairingEvent.Paired(peer), null)
    }

    private suspend fun sendRequest() {
        send(
            MessageType.PAIR_REQUEST,
            local.request(nonce = localNonce).toJson()
        )
    }

    private suspend fun send(type: MessageType, body: com.google.gson.JsonObject) {
        transport.send(
            EnvelopeCodec.frameFor(
                Envelope(
                    v = Envelope.CURRENT_VERSION,
                    id = UUID.randomUUID().toString().lowercase(),
                    type = requireNotNull(type.wireName),
                    ts = System.currentTimeMillis(),
                    body = body
                )
            )
        )
    }

    private suspend fun finish(event: PairingEvent, result: PairResultBody?) {
        if (finished) return
        finished = true
        if (result != null) {
            // Only a responder reports a refusal; an initiator has already been told, and a second
            // result confuses the peer's state machine.
            if (role == PeerSession.Role.RESPONDER) {
                runCatching { send(MessageType.PAIR_RESULT, result.toJson()) }
            }
        }
        events.trySend(event)
        events.close()
        transport.close()
    }

    private companion object {
        // Nothing sensitive is ever logged under this tag (protocol §11).
        const val TAG = "KlyndroPairing"
    }
}
