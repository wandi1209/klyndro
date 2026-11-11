import Foundation

/// Connection lifecycle as seen by the UI and the reconnect logic.
public enum ConnectionState: String, Sendable, Equatable, CaseIterable {
    case idle
    case discovering
    case connecting
    case securing
    case handshaking
    case connected
    case reconnecting
    case disconnecting
    case failed

    public var isActive: Bool {
        switch self {
        case .connected, .connecting, .securing, .handshaking, .reconnecting:
            return true
        case .idle, .discovering, .disconnecting, .failed:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .discovering: return "Searching"
        case .connecting: return "Connecting"
        case .securing: return "Securing"
        case .handshaking: return "Authenticating"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .disconnecting: return "Disconnecting"
        case .failed: return "Failed"
        }
    }
}

/// Inputs that drive `ConnectionStateMachine`.
public enum ConnectionEvent: Sendable, Equatable {
    case beginDiscovery
    case peerFound
    case connect
    case transportEstablished
    case transportFailed
    case securityEstablished
    case sessionEstablished
    case heartbeatMissed
    case peerClosed
    case disconnectRequested
    case disconnected
    case reset
}

public enum ConnectionStateError: Error, Equatable, Sendable {
    case invalidTransition(from: ConnectionState, event: ConnectionEvent)
}

/// Deterministic transition table. No timers, no I/O — so every edge is unit-testable
/// and both platforms can converge on the same rules.
public struct ConnectionStateMachine: Sendable {
    public private(set) var state: ConnectionState
    /// Consecutive failed attempts since the last successful session; feeds backoff.
    public private(set) var failureCount: Int

    public init(state: ConnectionState = .idle) {
        self.state = state
        self.failureCount = 0
    }

    @discardableResult
    public mutating func handle(_ event: ConnectionEvent) throws -> ConnectionState {
        guard let next = Self.nextState(from: state, on: event) else {
            throw ConnectionStateError.invalidTransition(from: state, event: event)
        }

        switch event {
        case .transportFailed, .heartbeatMissed:
            failureCount += 1
        case .peerClosed, .sessionEstablished, .reset:
            // A clean close after a healthy session starts the next attempt from the
            // initial delay; a transport failure escalates the backoff instead.
            failureCount = 0
        default:
            break
        }

        state = next
        return next
    }

    public static func nextState(
        from state: ConnectionState,
        on event: ConnectionEvent
    ) -> ConnectionState? {
        switch (state, event) {
        case (.idle, .beginDiscovery): return .discovering
        case (.idle, .connect), (.failed, .connect), (.reconnecting, .connect): return .connecting
        case (.idle, .reset), (.failed, .reset), (.reconnecting, .reset): return .idle

        case (.discovering, .peerFound): return .discovering
        case (.discovering, .connect): return .connecting
        case (.discovering, .disconnectRequested): return .idle
        case (.discovering, .reset): return .idle

        // `reset` is a hard force-to-idle used on teardown and unpair. It is valid from
        // anywhere except `.disconnecting`, where a graceful close is already in flight.
        case (.connecting, .reset), (.securing, .reset), (.handshaking, .reset),
             (.connected, .reset):
            return .idle

        case (.connecting, .transportEstablished): return .securing
        case (.connecting, .transportFailed): return .reconnecting
        case (.connecting, .disconnectRequested): return .disconnecting

        case (.securing, .securityEstablished): return .handshaking
        case (.securing, .transportFailed): return .reconnecting
        case (.securing, .disconnectRequested): return .disconnecting

        case (.handshaking, .sessionEstablished): return .connected
        case (.handshaking, .transportFailed): return .reconnecting
        case (.handshaking, .disconnectRequested): return .disconnecting

        case (.connected, .heartbeatMissed): return .reconnecting
        case (.connected, .peerClosed): return .reconnecting
        case (.connected, .transportFailed): return .reconnecting
        case (.connected, .disconnectRequested): return .disconnecting

        case (.reconnecting, .transportFailed): return .reconnecting

        case (.disconnecting, .disconnected): return .idle

        default: return nil
        }
    }
}
