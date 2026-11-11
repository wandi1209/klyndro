import Foundation
@testable import KlyndroKit

/// Collects session events so tests can assert on them without racing the stream.
actor EventRecorder {
    private(set) var events: [PeerSessionEvent] = []

    func record(_ event: PeerSessionEvent) {
        events.append(event)
    }

    func established() -> PeerSessionInfo? {
        for event in events {
            if case .established(let info) = event { return info }
        }
        return nil
    }

    func closeReason() -> SessionCloseReason? {
        for event in events {
            if case .closed(let reason) = event { return reason }
        }
        return nil
    }

    func messages() -> [Envelope] {
        events.compactMap {
            if case .message(let envelope) = $0 { return envelope }
            return nil
        }
    }

    func message(ofType type: MessageType) -> Envelope? {
        messages().first { $0.messageType == type }
    }

    // MARK: - Pairing

    private(set) var pairingEvents: [PairingEvent] = []

    func recordPairing(_ event: PairingEvent) {
        pairingEvents.append(event)
    }

    func pairingCode() -> String? {
        for event in pairingEvents {
            if case .awaitingConfirmation(let code, _) = event { return code }
        }
        return nil
    }

    func pairedPeer() -> TrustedPeer? {
        for event in pairingEvents {
            if case .paired(let peer) = event { return peer }
        }
        return nil
    }

    func pairingFailure() -> PairingFailure? {
        for event in pairingEvents {
            if case .failed(let failure) = event { return failure }
        }
        return nil
    }

    func consumePairing(_ stream: AsyncStream<PairingEvent>) {
        Task { [weak self] in
            for await event in stream {
                await self?.recordPairing(event)
            }
        }
    }

    /// Drives the stream in the background for the lifetime of the test.
    func consume(_ stream: AsyncStream<PeerSessionEvent>) {
        Task { [weak self] in
            for await event in stream {
                await self?.record(event)
            }
        }
    }
}

/// Polls `condition` until it is true or the deadline passes. Networking tests need this
/// instead of fixed sleeps: they fail fast on a slow machine and stay reliable on a fast one.
func pollUntil(
    timeout: Duration = .seconds(5),
    interval: Duration = .milliseconds(20),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}

/// Main-actor variant of `pollUntil`.
///
/// The clipboard tests are `@MainActor` because the pasteboard is, so the condition must stay on
/// the main actor instead of being sent to another isolation domain.
@MainActor
func pollUntilMain(
    timeout: Duration = .seconds(5),
    interval: Duration = .milliseconds(20),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}

func makeDeviceInfo(
    name: String,
    platform: Platform,
    capabilities: [Capability]
) -> LocalDeviceInfo {
    LocalDeviceInfo(
        deviceID: DeviceID(),
        name: name,
        platform: platform,
        appVersion: "0.1.0-test",
        capabilities: capabilities,
        fingerprint: Fingerprint(spki: Data(name.utf8))
    )
}
