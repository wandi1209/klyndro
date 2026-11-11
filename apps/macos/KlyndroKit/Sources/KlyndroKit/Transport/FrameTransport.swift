import Foundation

/// Bidirectional frame channel.
///
/// Deliberately narrow so the session logic can be tested over an in-memory channel and the
/// real implementation can be swapped without touching protocol code.
public protocol FrameTransport: Sendable {
    func send(_ frame: Frame) async throws
    /// Yields frames as they arrive; finishes when the peer closes, throws on transport failure.
    func incoming() -> AsyncThrowingStream<Frame, Error>
    func close()
}

/// A transport that can report the peer's public key as proven by the TLS handshake.
public protocol PeerKeyReporting: Sendable {
    /// DER SubjectPublicKeyInfo of the peer, or `nil` before the handshake completes.
    var peerPublicKey: Data? { get }
}

public enum TransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case closed
    case failed(String)
    case timedOut(String)

    public var description: String {
        switch self {
        case .closed: return "transport closed"
        case .failed(let reason): return "transport failed: \(reason)"
        case .timedOut(let operation): return "transport timed out: \(operation)"
        }
    }
}

/// In-memory pair of transports, for tests and previews.
public enum FrameTransportLoopback {
    public static func makePair() -> (client: InMemoryFrameTransport, server: InMemoryFrameTransport) {
        let clientToServer = Channel()
        let serverToClient = Channel()

        let client = InMemoryFrameTransport(incoming: serverToClient, outgoing: clientToServer)
        let server = InMemoryFrameTransport(incoming: clientToServer, outgoing: serverToClient)
        return (client, server)
    }

    final class Channel: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<Frame, Error>.Continuation?
        private var pending: [Frame] = []
        private var isClosed = false

        func attach(_ continuation: AsyncThrowingStream<Frame, Error>.Continuation) {
            lock.lock()
            let backlog = pending
            pending.removeAll()
            let closed = isClosed
            self.continuation = continuation
            lock.unlock()

            for frame in backlog { continuation.yield(frame) }
            if closed { continuation.finish() }
        }

        func push(_ frame: Frame) {
            lock.lock()
            let target = continuation
            if target == nil { pending.append(frame) }
            lock.unlock()
            target?.yield(frame)
        }

        func finish(_ error: Error? = nil) {
            lock.lock()
            isClosed = true
            let target = continuation
            lock.unlock()
            if let error {
                target?.finish(throwing: error)
            } else {
                target?.finish()
            }
        }
    }
}

public final class InMemoryFrameTransport: FrameTransport, PeerKeyReporting, @unchecked Sendable {
    private let incomingChannel: FrameTransportLoopback.Channel
    private let outgoingChannel: FrameTransportLoopback.Channel
    private let lock = NSLock()
    private var closed = false
    /// Set by tests to simulate the key the TLS layer would report for the peer.
    public var peerPublicKey: Data?

    init(
        incoming: FrameTransportLoopback.Channel,
        outgoing: FrameTransportLoopback.Channel
    ) {
        self.incomingChannel = incoming
        self.outgoingChannel = outgoing
    }

    public func send(_ frame: Frame) async throws {
        let isClosed = lock.withLock { closed }
        guard !isClosed else { throw TransportError.closed }
        outgoingChannel.push(frame)
    }

    public func incoming() -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream { continuation in
            incomingChannel.attach(continuation)
            continuation.onTermination = { @Sendable _ in }
        }
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        outgoingChannel.finish()
        incomingChannel.finish()
    }

    /// Simulates the peer dropping the connection.
    public func failWith(_ error: Error) {
        incomingChannel.finish(error)
    }
}
