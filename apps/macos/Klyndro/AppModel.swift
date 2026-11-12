import AppKit
import Foundation
import KlyndroKit
import Network
import Observation

/// A device Klyndro is connected to, or has paired with.
struct DeviceRow: Identifiable, Sendable, Hashable {
    let id: String
    var name: String
    var platform: String
    var fingerprintShort: String
    var connectionState: ConnectionState
    var supportsClipboard: Bool

    var isConnected: Bool { connectionState == .connected }
}

/// An in-flight pairing attempt, as shown in the pairing window.
struct PairingPrompt: Sendable, Equatable {
    var code: String
    var peerName: String
}

/// Application-wide state.
///
/// Services own their own state (listener, discovery, trust store); this type composes them for
/// the UI. Views never touch sockets or the Keychain directly.
@MainActor
@Observable
final class AppModel {
    private(set) var identity: DeviceIdentity?
    private(set) var identityError: String?
    private(set) var deviceID: DeviceID?
    private(set) var pairedPeers: [TrustedPeer] = []
    private(set) var discoveredPeers: [DiscoveredPeer] = []
    private(set) var devices: [DeviceRow] = []
    private(set) var toolchain: ToolchainReport?
    private(set) var isProbingToolchain = false
    private(set) var lastProbedAt: Date?

    private(set) var isListening = false
    private(set) var listenerError: String?
    private(set) var pairingPrompt: PairingPrompt?
    private(set) var pairingFailure: PairingFailure?
    private(set) var isPairingWindowOpen = false

    let mirroring = MirroringController()

    /// Outbound file transfer to the connected phone. Progress and the last result are surfaced so
    /// the UI never claims a file arrived when only the offer was sent.
    private(set) var fileSendProgress: Double?
    private(set) var fileSendMessage: String?
    private var fileSender: FileTransferSender?

    /// Clipboard activity, surfaced so "sync is on" is backed by something observable.
    private(set) var clipboardSentCount = 0
    private(set) var clipboardAppliedCount = 0
    private(set) var lastClipboardActivity: Date?

    private let trustStore: TrustStore = KeychainTrustStore()
    private var listener: KlyndroListener?
    private var discovery: BonjourDiscovery?
    private var pairingRunner: PairingRunner?
    private var pairingWindow: PairingWindow?
    private var activeSession: PeerSession?
    private var clipboard: ClipboardSync?
    private var pasteboardMonitor: PasteboardMonitor?
    private var pathMonitor: NWPathMonitor?
    private var tasks: [Task<Void, Never>] = []

    static let servicePort: UInt16 = 47_823

    var isConnected: Bool { devices.contains(where: \.isConnected) }

    var connectionSummary: String {
        if let connected = devices.first(where: \.isConnected) {
            return "Connected to \(connected.name)"
        }
        return pairedPeers.isEmpty ? "No paired devices" : "Not connected"
    }

    var identityFingerprintShort: String {
        identity?.fingerprint.shortHex ?? "—"
    }

    // MARK: - Lifecycle

    func start() async {
        guard identity == nil else { return }

        do {
            identity = try DeviceIdentityStore.loadOrCreate(commonName: Self.localDeviceName())
            NSLog("[Klyndro] Identity loaded: %@", identity?.fingerprint.shortHex ?? "nil")
        } catch {
            identityError = String(describing: error)
            NSLog("[Klyndro] Identity error: %@", String(describing: error))
            return
        }

        deviceID = Self.loadOrCreateDeviceID()
        refreshPeers()
        startDiscovery()
        await startListener(policy: pinnedPolicy())
        // The menu bar's mirroring item needs the toolchain result without opening the window.
        await probeToolchain()
        startNetworkMonitoring()
        registerSleepWakeNotifications()
        if UserDefaults.standard.bool(forKey: PreferenceKeys.notificationsEnabled) {
            Task { _ = await NotificationCenterForwarder.shared.requestAuthorization() }
        }
    }

    func shutDown() {
        mirroring.stop()
        stopNetworkMonitoring()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        clipboard?.stop()
        clipboard = nil
        pasteboardMonitor = nil
        discovery?.stopBrowsing()
        listener?.stop()
        listener = nil
    }

    // MARK: - Devices

    func refreshPeers() {
        pairedPeers = (try? trustStore.allPeers()) ?? []
        rebuildDeviceRows()
    }

    func unpair(_ peer: TrustedPeer) {
        try? trustStore.remove(id: peer.deviceID)
        refreshPeers()
        Task { await restartListenerIfNeeded() }
    }

    // MARK: - Sleep / Wake & Network Monitoring

    private func startNetworkMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if path.status == .satisfied {
                    NSLog("[Klyndro] network path satisfied, checking listener")
                    await self.restartListenerIfNeeded()
                }
            }
        }
        let queue = DispatchQueue(label: "id.my.wandidev.klyndro.pathmonitor")
        monitor.start(queue: queue)
        self.pathMonitor = monitor
    }

    private func stopNetworkMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func registerSleepWakeNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                NSLog("[Klyndro] system woke from sleep, restarting listener")
                await self.restartListenerIfNeeded()
            }
        }
    }

    /// Applies a preference change to the running session without requiring a reconnect.
    func applyClipboardPreferences() {
        let enabled = UserDefaults.standard.object(forKey: PreferenceKeys.clipboardSyncEnabled) as? Bool ?? true
        let allowsSensitive = UserDefaults.standard.bool(forKey: PreferenceKeys.allowSensitiveClipboard)
        clipboard?.setEnabled(enabled)
        clipboard?.setAllowsSensitive(allowsSensitive)
    }

    func probeToolchain() async {
        guard !isProbingToolchain else { return }
        isProbingToolchain = true
        defer { isProbingToolchain = false }
        toolchain = await ToolchainProbe.probe()
        lastProbedAt = Date()
        mirroring.updateToolchain(toolchain)
        await mirroring.refreshDevices()
        await mirroring.autoConnectIfNeeded()
    }

    // MARK: - File transfer to the phone

    var canSendFile: Bool { fileSender != nil && fileSendProgress == nil }

    func sendFile(at url: URL) async {
        guard let sender = fileSender else {
            fileSendMessage = "Connect to a phone first."
            return
        }
        fileSendMessage = nil
        fileSendProgress = 0
        defer { fileSendProgress = nil }
        do {
            let name = try await sender.sendFile(at: url) { [weak self] fraction in
                Task { @MainActor in self?.fileSendProgress = fraction }
            }
            // The phone confirms nothing after `file.complete`; it verifies the hash itself and
            // posts its own notification. Say only what this side knows.
            fileSendMessage = "Sent \(name). The phone checks it and shows a notification when saved."
        } catch let error as FileSendError {
            fileSendMessage = error.description
        } catch {
            fileSendMessage = "Sending failed."
        }
    }

    // MARK: - Deep links

    /// Handles `klyndro://` URLs.
    func handle(url: URL) async {
        guard url.scheme == "klyndro" else { return }
        switch url.host {
        case "pair":
            await beginPairing()
        case "mirror":
            // klyndro://mirror/start | stop — scripted verification and shortcuts.
            switch url.path {
            case "/stop": mirroring.stop()
            default:
                await mirroring.startOrGuide()
            }
        default:
            break
        }
    }

    // MARK: - Pairing

    func beginPairing() async {
        guard identity != nil else { return }
        let window = PairingWindow()
        pairingWindow = window
        isPairingWindowOpen = true
        pairingPrompt = nil
        pairingFailure = nil

        // The listener must accept an unpinned certificate while the window is open, and only
        // then. Restarting it with a different policy is the smallest correct implementation.
        await startListener(policy: .pairingOnly)

        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(PairingWindow.defaultDuration))
            await self?.closePairingWindow()
        })
    }

    func confirmPairing() async {
        await pairingRunner?.confirm()
    }

    func dismissPairingSheet() {
        pairingFailure = nil
        pairingPrompt = nil
        Task { await cancelPairing() }
    }

    func cancelPairing() async {
        await pairingRunner?.reject()
        pairingFailure = nil
        pairingPrompt = nil
        await closePairingWindow()
    }

    private func closePairingWindow() async {
        isPairingWindowOpen = false
        pairingWindow = nil
        pairingPrompt = nil
        pairingRunner = nil
        if identity != nil {
            await startListener(policy: pinnedPolicy())
        }
    }

    // MARK: - Listener

    private func pinnedPolicy() -> PinPolicy {
        PinPolicy.pinned((try? trustStore.allPeers()) ?? [])
    }

    private func startListener(policy: PinPolicy) async {
        guard let identity else { return }

        if let existing = listener {
            existing.stop()
            listener = nil
            // Allow kernel to release the listening port before rebinding
            try? await Task.sleep(for: .milliseconds(150))
        }
        isListening = false
        listenerError = nil

        let advertised = BonjourDiscovery.service(
            deviceID: deviceID ?? DeviceID(),
            name: Self.localDeviceName(),
            fingerprint: identity.fingerprint,
            capabilities: Self.localCapabilities
        )

        do {
            let listener = try KlyndroListener(
                identity: identity,
                policy: policy,
                service: advertised,
                port: NWEndpoint.Port(rawValue: Self.servicePort) ?? .any
            ) { [weak self] transport in
                Task { await self?.handle(transport) }
            }
            try await listener.start()
            self.listener = listener
            isListening = true
            NSLog("[Klyndro] Listener started on port: %d, policy: %@", Self.servicePort, String(describing: policy))
        } catch {
            listenerError = "Could not start listening: \(error)"
            NSLog("[Klyndro] Listener error: %@", String(describing: error))
        }
    }

    private func restartListenerIfNeeded() async {
        guard !isPairingWindowOpen else { return }
        await startListener(policy: pinnedPolicy())
    }

    /// A connection either belongs to an open pairing window or must present a pinned identity.
    private func handle(_ transport: NWFrameTransport) async {
        guard let identity else { return }
        NSLog("[Klyndro] accepted connection, pairing window open: %d", isPairingWindowOpen ? 1 : 0)

        if isPairingWindowOpen, let window = pairingWindow {
            let remote = transport.remoteEndpoint
            let runner = PairingRunner(
                transport: transport,
                local: PairingLocalInfo(
                    deviceID: deviceID ?? DeviceID(),
                    name: Self.localDeviceName(),
                    platform: .macos,
                    capabilities: Self.localCapabilities,
                    fingerprint: identity.fingerprint
                ),
                role: .responder,
                trustStore: trustStore,
                window: window,
                peerHost: remote?.host,
                peerPort: remote.map { Int($0.port) }
            )
            pairingRunner = runner

            let events = await runner.events()
            tasks.append(Task { [weak self] in
                for await event in events {
                    await self?.handlePairingEvent(event)
                }
            })
            await runner.start()
            return
        }

        let session = PeerSession(
            transport: transport,
            local: LocalDeviceInfo(
                deviceID: deviceID ?? DeviceID(),
                name: Self.localDeviceName(),
                platform: .macos,
                appVersion: BuildInfo.appVersion,
                capabilities: Self.localCapabilities,
                fingerprint: identity.fingerprint
            ),
            role: .responder
        )
        activeSession = session

        let events = await session.events()
        tasks.append(Task { [weak self, session] in
            for await event in events {
                await self?.handleSessionEvent(event, session: session)
            }
        })
        await session.start()
    }

    private func handlePairingEvent(_ event: PairingEvent) async {
        switch event {
        case .awaitingConfirmation(let code, let peerName):
            pairingPrompt = PairingPrompt(code: code, peerName: peerName)
            #if DEBUG
            // Test-only stand-in for the human who compares the digits. Guarded by DEBUG *and* an
            // explicit environment variable, so it cannot be reached in a release build or by
            // simply running the app.
            if ProcessInfo.processInfo.environment["KLYNDRO_AUTOCONFIRM_PAIRING"] == "1" {
                await confirmPairing()
            }
            #endif
        case .paired(let peer):
            pairingPrompt = nil
            refreshPeers()
            await closePairingWindow()
            _ = peer
        case .failed(let failure):
            pairingFailure = failure
            pairingPrompt = nil
            await closePairingWindow()
        }
    }

    /// Starts clipboard sync once a session is authenticated and both sides support it.
    private func startClipboardIfSupported(_ info: PeerSessionInfo, session: PeerSession) async {
        guard info.supportsClipboard, let deviceID else { return }

        await stopClipboard()

        let pasteboard = SystemPasteboard()
        let enabled = UserDefaults.standard.object(forKey: PreferenceKeys.clipboardSyncEnabled) as? Bool ?? true
        let allowsSensitive = UserDefaults.standard.bool(forKey: PreferenceKeys.allowSensitiveClipboard)

        let monitor = PasteboardMonitor(pasteboard: pasteboard) { [weak self] snapshot in
            Task { await self?.handleLocalClipboardChange(snapshot) }
        }
        pasteboardMonitor = monitor

        let sync = ClipboardSync(
            deviceID: deviceID,
            pasteboard: pasteboard,
            monitor: monitor,
            session: session,
            isEnabled: enabled,
            allowsSensitive: allowsSensitive
        )
        clipboard = sync
        sync.start()
    }

    private func stopClipboard() async {
        clipboard?.stop()
        clipboard = nil
        pasteboardMonitor = nil
        clipboardSentCount = 0
        clipboardAppliedCount = 0
    }

    private func handleLocalClipboardChange(_ snapshot: ClipboardSnapshot) async {
        guard let clipboard else { return }
        await clipboard.localClipboardChanged(snapshot)
        clipboardSentCount = clipboard.sentCount
        if clipboard.sentCount > 0 { lastClipboardActivity = Date() }
    }

    private func handleIncomingMessage(_ envelope: Envelope) async {
        switch envelope.messageType {
        case .clipboardUpdate, .clipboardAck:
            await handleClipboardMessage(envelope)
        case .notificationPost:
            let notificationsEnabled = UserDefaults.standard.bool(forKey: PreferenceKeys.notificationsEnabled)
            guard notificationsEnabled else { return }
            guard let post = try? NotificationMessageCodec.decodePost(envelope) else { return }
            NSLog("[Klyndro] forwarding notification from %{public}@", post.appName)
            _ = await NotificationCenterForwarder.shared.requestAuthorization()
            await NotificationCenterForwarder.shared.post(post)
        case .fileAccept, .fileReject:
            await fileSender?.handleAnswer(envelope)
        case .fileOffer:
            guard let offer = try? FileMessageCodec.decodeOffer(envelope) else { return }
            let accepted = await FileTransferReceiver.shared.handleOffer(offer)
            let replyType: MessageType = accepted ? .fileAccept : .fileReject
            var replyObj: [String: JSONValue] = ["transfer_id": .string(offer.transferId)]
            if !accepted { replyObj["reason"] = .string("busy") }
            try? await activeSession?.send(Envelope(type: replyType, body: .object(replyObj)))
        case .fileChunk:
            guard let body = envelope.body,
                  let tid = body["transfer_id"]?.stringValue,
                  let offset = body["offset"]?.intValue,
                  let b64 = body["data_b64"]?.stringValue else { return }
            _ = await FileTransferReceiver.shared.handleChunk(
                FileChunkBody(transferId: tid, offset: Int64(offset), dataB64: b64)
            )
        case .fileComplete:
            guard let body = envelope.body,
                  let tid = body["transfer_id"]?.stringValue,
                  let sha = body["sha256"]?.stringValue else { return }
            if let savedURL = await FileTransferReceiver.shared.handleComplete(
                FileCompleteBody(transferId: tid, sha256: sha)
            ) {
                let post = NotificationPostBody(
                    key: "klyndro-file:\(tid)",
                    package: "id.my.wandidev.klyndro",
                    appName: "Klyndro File Transfer",
                    title: "File Received",
                    text: savedURL.lastPathComponent,
                    postedAt: Envelope.now(),
                    sensitive: false
                )
                _ = await NotificationCenterForwarder.shared.requestAuthorization()
                await NotificationCenterForwarder.shared.post(post)
            }
        default:
            break
        }
    }

    private func handleClipboardMessage(_ envelope: Envelope) async {
        guard let clipboard else { return }

        switch envelope.messageType {
        case .clipboardUpdate:
            guard let body = try? ClipboardMessageCodec.decodeUpdate(envelope) else { return }
            await clipboard.remoteClipboardChanged(body, refID: envelope.id)
            clipboardAppliedCount = clipboard.appliedCount
            if clipboard.appliedCount > 0 { lastClipboardActivity = Date() }
        case .clipboardAck:
            // Acknowledgements are informational; nothing to do beyond not treating them as text.
            break
        default:
            break
        }
    }

    private func handleSessionEvent(_ event: PeerSessionEvent, session: PeerSession) async {
        switch event {
        case .established(let info):
            NSLog("[Klyndro] session established with %@", info.name)
            upsertConnectedDevice(info, state: .connected)
            await startClipboardIfSupported(info, session: session)
            fileSender = FileTransferSender { [weak session] envelope in
                guard let session else { throw FileSendError.sendFailed }
                try await session.send(envelope)
            }
            // A paired phone just came online on this network; make it available to mirroring too.
            await mirroring.autoConnectIfNeeded()
        case .message(let envelope):
            await handleIncomingMessage(envelope)
        case .closed:
            NSLog("[Klyndro] session closed")
            await stopClipboard()
            fileSender = nil
            fileSendProgress = nil
            activeSession = nil
            devices = devices.map { row in
                var updated = row
                updated.connectionState = row.isConnected ? .reconnecting : row.connectionState
                return updated
            }
        }
    }

    private func upsertConnectedDevice(_ info: PeerSessionInfo, state: ConnectionState) {
        if let index = devices.firstIndex(where: { $0.id == info.deviceID.hex }) {
            devices[index].connectionState = state
            devices[index].supportsClipboard = info.supportsClipboard
        } else {
            devices.append(
                DeviceRow(
                    id: info.deviceID.hex,
                    name: info.name,
                    platform: info.platform.rawValue,
                    fingerprintShort: info.fingerprint.shortHex,
                    connectionState: state,
                    supportsClipboard: info.supportsClipboard
                )
            )
        }
    }

    private func rebuildDeviceRows() {
        let connectedByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        devices = pairedPeers.map { peer in
            if let existing = connectedByID[peer.deviceID] {
                return existing
            }
            return DeviceRow(
                id: peer.deviceID,
                name: peer.name,
                platform: peer.platform,
                fingerprintShort: peer.fingerprintValue?.shortHex ?? "—",
                connectionState: .idle,
                supportsClipboard: false
            )
        }
    }

    // MARK: - Discovery

    private func startDiscovery() {
        let discovery = BonjourDiscovery { [trustStore] in
            (try? trustStore.allPeers()) ?? []
        }
        self.discovery = discovery

        let stream = discovery.browse()
        tasks.append(Task { [weak self] in
            for await peers in stream {
                await MainActor.run {
                    self?.discoveredPeers = peers
                }
            }
        })
    }

    // MARK: - Environment

    static let localCapabilities: [Capability] = [.clipboard, .notifications, .fileTransfer, .mirroring, .presence]

    static func localDeviceName() -> String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return name.isEmpty ? "Mac" : name
    }

    private static let deviceIDKey = "klyndro.deviceID"

    static func loadOrCreateDeviceID() -> DeviceID {
        if let stored = UserDefaults.standard.string(forKey: deviceIDKey),
           let id = DeviceID(hex: stored) {
            return id
        }
        let id = DeviceID()
        UserDefaults.standard.set(id.hex, forKey: deviceIDKey)
        return id
    }
}
