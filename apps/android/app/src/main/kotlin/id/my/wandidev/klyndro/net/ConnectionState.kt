package id.my.wandidev.klyndro.net

/** Connection lifecycle, kept in step with the macOS `ConnectionState`. */
enum class ConnectionState(val displayName: String) {
    IDLE("Idle"),
    DISCOVERING("Searching"),
    CONNECTING("Connecting"),
    SECURING("Securing"),
    HANDSHAKING("Authenticating"),
    CONNECTED("Connected"),
    RECONNECTING("Reconnecting"),
    DISCONNECTING("Disconnecting"),
    FAILED("Failed");

    val isActive: Boolean
        get() = this in setOf(CONNECTED, CONNECTING, SECURING, HANDSHAKING, RECONNECTING)
}

/** Inputs that drive [ConnectionStateMachine]. */
sealed interface ConnectionEvent {
    data object BeginDiscovery : ConnectionEvent
    data object PeerFound : ConnectionEvent
    data object Connect : ConnectionEvent
    data object TransportEstablished : ConnectionEvent
    data object TransportFailed : ConnectionEvent
    data object SecurityEstablished : ConnectionEvent
    data object SessionEstablished : ConnectionEvent
    data object HeartbeatMissed : ConnectionEvent
    data object PeerClosed : ConnectionEvent
    data object DisconnectRequested : ConnectionEvent
    data object Disconnected : ConnectionEvent
    data object Reset : ConnectionEvent
}

class InvalidTransitionException(val from: ConnectionState, val event: ConnectionEvent) :
    IllegalStateException("invalid transition from ${from.name} on $event")

/**
 * Deterministic transition table with no I/O, so every edge is unit-testable and the two
 * platform implementations can converge.
 */
class ConnectionStateMachine(initial: ConnectionState = ConnectionState.IDLE) {

    var state: ConnectionState = initial
        private set

    /** Consecutive failures since the last successful session; feeds backoff. */
    var failureCount: Int = 0
        private set

    fun handle(event: ConnectionEvent): ConnectionState {
        val next = nextState(state, event)
            ?: throw InvalidTransitionException(state, event)

        when (event) {
            ConnectionEvent.TransportFailed, ConnectionEvent.HeartbeatMissed -> failureCount++
            // A clean close after a healthy session starts the next attempt from the
            // initial delay; a transport failure escalates the backoff instead.
            ConnectionEvent.PeerClosed,
            ConnectionEvent.SessionEstablished,
            ConnectionEvent.Reset -> failureCount = 0
            else -> Unit
        }

        state = next
        return next
    }

    companion object {
        fun nextState(from: ConnectionState, event: ConnectionEvent): ConnectionState? =
            when (from to event) {
                ConnectionState.IDLE to ConnectionEvent.BeginDiscovery -> ConnectionState.DISCOVERING
                ConnectionState.IDLE to ConnectionEvent.Connect,
                ConnectionState.FAILED to ConnectionEvent.Connect,
                ConnectionState.RECONNECTING to ConnectionEvent.Connect -> ConnectionState.CONNECTING

                ConnectionState.IDLE to ConnectionEvent.Reset,
                ConnectionState.FAILED to ConnectionEvent.Reset,
                ConnectionState.RECONNECTING to ConnectionEvent.Reset -> ConnectionState.IDLE

                ConnectionState.DISCOVERING to ConnectionEvent.PeerFound -> ConnectionState.DISCOVERING
                ConnectionState.DISCOVERING to ConnectionEvent.Connect -> ConnectionState.CONNECTING
                ConnectionState.DISCOVERING to ConnectionEvent.DisconnectRequested -> ConnectionState.IDLE
                ConnectionState.DISCOVERING to ConnectionEvent.Reset -> ConnectionState.IDLE

                ConnectionState.CONNECTING to ConnectionEvent.TransportEstablished -> ConnectionState.SECURING
                ConnectionState.CONNECTING to ConnectionEvent.TransportFailed -> ConnectionState.RECONNECTING
                ConnectionState.CONNECTING to ConnectionEvent.DisconnectRequested -> ConnectionState.DISCONNECTING

                ConnectionState.SECURING to ConnectionEvent.SecurityEstablished -> ConnectionState.HANDSHAKING
                ConnectionState.SECURING to ConnectionEvent.TransportFailed -> ConnectionState.RECONNECTING
                ConnectionState.SECURING to ConnectionEvent.DisconnectRequested -> ConnectionState.DISCONNECTING

                ConnectionState.HANDSHAKING to ConnectionEvent.SessionEstablished -> ConnectionState.CONNECTED
                ConnectionState.HANDSHAKING to ConnectionEvent.TransportFailed -> ConnectionState.RECONNECTING
                ConnectionState.HANDSHAKING to ConnectionEvent.DisconnectRequested -> ConnectionState.DISCONNECTING

                ConnectionState.CONNECTED to ConnectionEvent.HeartbeatMissed -> ConnectionState.RECONNECTING
                ConnectionState.CONNECTED to ConnectionEvent.PeerClosed -> ConnectionState.RECONNECTING
                ConnectionState.CONNECTED to ConnectionEvent.TransportFailed -> ConnectionState.RECONNECTING
                ConnectionState.CONNECTED to ConnectionEvent.DisconnectRequested -> ConnectionState.DISCONNECTING

                ConnectionState.RECONNECTING to ConnectionEvent.TransportFailed -> ConnectionState.RECONNECTING

                ConnectionState.DISCONNECTING to ConnectionEvent.Disconnected -> ConnectionState.IDLE

                // `reset` is a hard force-to-idle used on teardown and unpair.
                ConnectionState.CONNECTING to ConnectionEvent.Reset,
                ConnectionState.SECURING to ConnectionEvent.Reset,
                ConnectionState.HANDSHAKING to ConnectionEvent.Reset,
                ConnectionState.CONNECTED to ConnectionEvent.Reset -> ConnectionState.IDLE

                else -> null
            }
    }
}
