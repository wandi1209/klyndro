import KlyndroKit
import Testing

@Suite("Connection state machine")
struct ConnectionStateMachineTests {
    @Test("walks a healthy connection from idle to connected")
    func happyPath() throws {
        var machine = ConnectionStateMachine()
        #expect(try machine.handle(.beginDiscovery) == .discovering)
        #expect(try machine.handle(.peerFound) == .discovering)
        #expect(try machine.handle(.connect) == .connecting)
        #expect(try machine.handle(.transportEstablished) == .securing)
        #expect(try machine.handle(.securityEstablished) == .handshaking)
        #expect(try machine.handle(.sessionEstablished) == .connected)
        #expect(machine.failureCount == 0)
    }

    @Test("rejects transitions that cannot happen")
    func rejectsInvalidTransition() {
        var machine = ConnectionStateMachine()
        #expect(throws: ConnectionStateError.invalidTransition(from: .idle, event: .sessionEstablished)) {
            try machine.handle(.sessionEstablished)
        }
        #expect(machine.state == .idle)
    }

    @Test("counts transport failures and resets on success")
    func failureAccounting() throws {
        var machine = ConnectionStateMachine(state: .connecting)
        try machine.handle(.transportFailed)
        #expect(machine.state == .reconnecting)
        #expect(machine.failureCount == 1)

        try machine.handle(.connect)
        try machine.handle(.transportFailed)
        #expect(machine.failureCount == 2)

        try machine.handle(.connect)
        try machine.handle(.transportEstablished)
        try machine.handle(.securityEstablished)
        try machine.handle(.sessionEstablished)
        #expect(machine.failureCount == 0, "a successful session clears the backoff counter")
    }

    @Test("a clean peer close starts the next attempt from the initial delay")
    func peerCloseResetsBackoff() throws {
        var machine = ConnectionStateMachine(state: .connected)
        try machine.handle(.peerClosed)
        #expect(machine.state == .reconnecting)
        #expect(machine.failureCount == 0)
    }

    @Test("a missed heartbeat escalates backoff")
    func heartbeatMissEscalates() throws {
        var machine = ConnectionStateMachine(state: .connected)
        try machine.handle(.heartbeatMissed)
        #expect(machine.state == .reconnecting)
        #expect(machine.failureCount == 1)
    }

    @Test("user disconnect returns to idle")
    func disconnectReturnsToIdle() throws {
        var machine = ConnectionStateMachine(state: .connected)
        try machine.handle(.disconnectRequested)
        #expect(machine.state == .disconnecting)
        try machine.handle(.disconnected)
        #expect(machine.state == .idle)
        #expect(!machine.state.isActive)
    }

    @Test("reset is allowed from every recoverable state")
    func resetFromEveryState() throws {
        for state in ConnectionState.allCases where state != .disconnecting {
            var machine = ConnectionStateMachine(state: state)
            #expect(try machine.handle(.reset) == .idle, "reset failed from \(state)")
        }
    }

    @Test("every declared state has a display name")
    func displayNamesArePresent() {
        for state in ConnectionState.allCases {
            #expect(!state.displayName.isEmpty)
        }
    }
}
