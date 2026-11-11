package id.my.wandidev.klyndro.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class ConnectionStateMachineTest {

    @Test
    fun `walks a healthy connection from idle to connected`() {
        val machine = ConnectionStateMachine()

        assertEquals(ConnectionState.DISCOVERING, machine.handle(ConnectionEvent.BeginDiscovery))
        assertEquals(ConnectionState.DISCOVERING, machine.handle(ConnectionEvent.PeerFound))
        assertEquals(ConnectionState.CONNECTING, machine.handle(ConnectionEvent.Connect))
        assertEquals(ConnectionState.SECURING, machine.handle(ConnectionEvent.TransportEstablished))
        assertEquals(ConnectionState.HANDSHAKING, machine.handle(ConnectionEvent.SecurityEstablished))
        assertEquals(ConnectionState.CONNECTED, machine.handle(ConnectionEvent.SessionEstablished))
        assertEquals(0, machine.failureCount)
    }

    @Test
    fun `rejects transitions that cannot happen`() {
        val machine = ConnectionStateMachine()

        assertThrows(InvalidTransitionException::class.java) {
            machine.handle(ConnectionEvent.SessionEstablished)
        }
        assertEquals(ConnectionState.IDLE, machine.state)
    }

    @Test
    fun `counts transport failures and resets on success`() {
        val machine = ConnectionStateMachine(ConnectionState.CONNECTING)

        machine.handle(ConnectionEvent.TransportFailed)
        assertEquals(ConnectionState.RECONNECTING, machine.state)
        assertEquals(1, machine.failureCount)

        machine.handle(ConnectionEvent.Connect)
        machine.handle(ConnectionEvent.TransportFailed)
        assertEquals(2, machine.failureCount)

        machine.handle(ConnectionEvent.Connect)
        machine.handle(ConnectionEvent.TransportEstablished)
        machine.handle(ConnectionEvent.SecurityEstablished)
        machine.handle(ConnectionEvent.SessionEstablished)
        assertEquals(0, machine.failureCount)
    }

    @Test
    fun `a clean peer close starts the next attempt from the initial delay`() {
        val machine = ConnectionStateMachine(ConnectionState.CONNECTED)

        machine.handle(ConnectionEvent.PeerClosed)

        assertEquals(ConnectionState.RECONNECTING, machine.state)
        assertEquals(0, machine.failureCount)
    }

    @Test
    fun `a missed heartbeat escalates backoff`() {
        val machine = ConnectionStateMachine(ConnectionState.CONNECTED)

        machine.handle(ConnectionEvent.HeartbeatMissed)

        assertEquals(ConnectionState.RECONNECTING, machine.state)
        assertEquals(1, machine.failureCount)
    }

    @Test
    fun `user disconnect returns to idle`() {
        val machine = ConnectionStateMachine(ConnectionState.CONNECTED)

        machine.handle(ConnectionEvent.DisconnectRequested)
        assertEquals(ConnectionState.DISCONNECTING, machine.state)

        machine.handle(ConnectionEvent.Disconnected)
        assertEquals(ConnectionState.IDLE, machine.state)
        assertFalse(machine.state.isActive)
    }

    @Test
    fun `reset is allowed from every recoverable state`() {
        ConnectionState.entries
            .filter { it != ConnectionState.DISCONNECTING }
            .forEach { state ->
                val machine = ConnectionStateMachine(state)
                assertEquals("reset failed from $state", ConnectionState.IDLE, machine.handle(ConnectionEvent.Reset))
            }
    }

    @Test
    fun `every state has a display name`() {
        ConnectionState.entries.forEach { state ->
            assertFalse(state.displayName.isBlank())
        }
    }
}
