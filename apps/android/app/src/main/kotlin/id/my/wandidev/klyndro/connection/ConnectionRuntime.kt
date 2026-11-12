package id.my.wandidev.klyndro.connection

import id.my.wandidev.klyndro.protocol.Envelope
import id.my.wandidev.klyndro.protocol.MirrorStreamStartBody
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

/** What the UI needs to know about the connection, without touching sockets. */
data class ConnectionStatus(
    val serviceRunning: Boolean = false,
    val phase: Phase = Phase.IDLE,
    val peerName: String? = null,
    val identityShort: String? = null,
    val clipboardSentCount: Int = 0,
    val clipboardAppliedCount: Int = 0,
    /** Present while a pairing code must be compared. */
    val pairingCode: String? = null,
    /** Present when the Mac requested Standard Mirroring and needs user screen-capture consent. */
    val pendingMirrorStream: MirrorStreamStartBody? = null,
    val standardMirroring: Boolean = false,
    val lastError: String? = null
) {
    enum class Phase {
        IDLE,
        SEARCHING,
        CONNECTING,
        PAIRING,
        CONNECTED,
        STOPPED,
        ERROR
    }
}

/**
 * The single seam between the foreground service (which owns the socket) and the UI (which owns
 * the clipboard).
 *
 * A deliberate simplification: there is exactly one connection, so a process-wide holder is
 * clearer than a bound-service interface, and it keeps the clipboard code free of IPC. The split
 * itself is forced by Android: a foreground service may hold a socket but may not read the
 * clipboard, so clipboard work has to happen while an Activity is visible.
 */
/** A device seen on the network, before any trust decision. */
data class DiscoveredEntry(
    val name: String,
    val deviceId: String,
    val host: String,
    val port: Int,
    val hostName: String? = null
)

object ConnectionRuntime {
    private val _status = MutableStateFlow(ConnectionStatus())
    val status: StateFlow<ConnectionStatus> = _status

    /** Clipboard messages arriving from the peer, for the foreground UI to apply. */
    private val _inbound = MutableSharedFlow<Envelope>(extraBufferCapacity = 32)
    val inbound: SharedFlow<Envelope> = _inbound

    private val _discovered = MutableStateFlow<List<DiscoveredEntry>>(emptyList())
    val discovered: StateFlow<List<DiscoveredEntry>> = _discovered

    @Volatile
    private var sender: (suspend (Envelope) -> Boolean)? = null

    fun update(transform: (ConnectionStatus) -> ConnectionStatus) {
        _status.value = transform(_status.value)
    }

    fun setStatus(status: ConnectionStatus) {
        _status.value = status
    }

    fun attachSender(send: suspend (Envelope) -> Boolean) {
        sender = send
    }

    fun detachSender() {
        sender = null
    }

    suspend fun send(envelope: Envelope): Boolean = sender?.invoke(envelope) ?: false

    fun publishInbound(envelope: Envelope) {
        _inbound.tryEmit(envelope)
    }

    fun noteClipboardCounts(sent: Int, applied: Int) {
        update { it.copy(clipboardSentCount = sent, clipboardAppliedCount = applied) }
    }

    /** Confirmation of the six-digit code, sent from the UI to the service. */
    val pairingDecisions = Channel<Boolean>(Channel.CONFLATED)

    fun setDiscovered(entries: List<DiscoveredEntry>) {
        _discovered.value = entries
    }

    fun clearPairingCode() {
        update { it.copy(pairingCode = null) }
    }

    fun setPendingMirrorStream(request: MirrorStreamStartBody?) {
        update { it.copy(pendingMirrorStream = request) }
    }

    fun setStandardMirroring(active: Boolean) {
        update { it.copy(standardMirroring = active) }
    }
}
