package id.my.wandidev.klyndro.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import id.my.wandidev.klyndro.BuildConfig
import id.my.wandidev.klyndro.MainActivity
import id.my.wandidev.klyndro.R
import id.my.wandidev.klyndro.connection.ConnectionRuntime
import id.my.wandidev.klyndro.connection.ConnectionStatus
import id.my.wandidev.klyndro.connection.DiscoveredEntry
import id.my.wandidev.klyndro.connection.MirrorProofResponder
import id.my.wandidev.klyndro.discovery.NsdDiscovery
import id.my.wandidev.klyndro.filetransfer.AndroidFileReceiver
import id.my.wandidev.klyndro.crypto.AndroidKeyStoreIdentities
import id.my.wandidev.klyndro.crypto.DeviceIdentity
import id.my.wandidev.klyndro.crypto.EncryptedTrustStore
import id.my.wandidev.klyndro.crypto.KeystoreSecretBox
import id.my.wandidev.klyndro.crypto.PairingWindow
import id.my.wandidev.klyndro.crypto.TrustStore
import id.my.wandidev.klyndro.net.LocalDeviceInfo
import id.my.wandidev.klyndro.net.PairingEvent
import id.my.wandidev.klyndro.net.PairingLocalInfo
import id.my.wandidev.klyndro.net.PairingRunner
import id.my.wandidev.klyndro.net.PeerSession
import id.my.wandidev.klyndro.net.PeerSessionEvent
import id.my.wandidev.klyndro.net.PinPolicy
import id.my.wandidev.klyndro.net.ReconnectPolicy
import id.my.wandidev.klyndro.net.TlsClient
import id.my.wandidev.klyndro.protocol.Capability
import id.my.wandidev.klyndro.protocol.DeviceId
import id.my.wandidev.klyndro.protocol.MessageType
import id.my.wandidev.klyndro.protocol.Platform
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Holds the connection to the paired Mac.
 *
 * A foreground service, because the connection must survive the Activity going to the background
 * and because Android 14+ requires a declared service type for exactly this case
 * (`connectedDevice`).
 *
 * It deliberately does **not** touch the clipboard: the platform forbids that from the background,
 * so clipboard work lives in the UI layer and is only active while the app is visible. Pretending
 * otherwise would be the single easiest way to ship a feature that silently does nothing.
 */
class KlyndroService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val reconnectPolicy = ReconnectPolicy()
    private var reconnectAttempt = 0
    private var connectionJob: Job? = null
    private var identity: DeviceIdentity? = null
    private var trustStore: TrustStore? = null
    private var session: PeerSession? = null
    private var fileReceiver: AndroidFileReceiver? = null
    private val mirrorProof by lazy {
        MirrorProofResponder(
            directory = { getExternalFilesDir(null) },
            scheduleCleanup = { file ->
                scope.launch {
                    kotlinx.coroutines.delay(60_000)
                    runCatching { file.delete() }
                }
            }
        )
    }
    private var pairingRunner: PairingRunner? = null
    private var discovery: NsdDiscovery? = null
    private val discovered = LinkedHashMap<String, DiscoveredEntry>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startDiscovery()
        // Pairing decisions come from the UI, which is the only place a human can tap a button.
        scope.launch {
            for (confirmed in ConnectionRuntime.pairingDecisions) {
                val runner = pairingRunner ?: continue
                if (confirmed) runner.confirm() else runner.reject()
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // `startForeground` must be called promptly or the system kills the service.
        startForeground(NOTIFICATION_ID, buildNotification(getString(R.string.service_status_starting)))

        when (intent?.action) {
            ACTION_PAIR -> {
                val rawHost = intent.getStringExtra(EXTRA_HOST)
                val host = rawHost?.let { preferReachableAddress(it, intent.getStringExtra(EXTRA_HOSTNAME)) }
                val port = intent.getIntExtra(EXTRA_PORT, 0)
                if (host != null && port > 0) {
                    ConnectionRuntime.update {
                        it.copy(serviceRunning = true, phase = ConnectionStatus.Phase.PAIRING)
                    }
                    startPairing(host, port)
                }
            }

            ACTION_CONNECT -> {
                ConnectionRuntime.update { it.copy(serviceRunning = true) }
                startConnecting()
            }

            ACTION_STOP -> {
                shutdown()
                stopSelf()
            }

            else -> ConnectionRuntime.update { it.copy(serviceRunning = true) }
        }

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }

    // MARK: - Pairing

    private fun startPairing(host: String, port: Int) {
        connectionJob?.cancel()
        connectionJob = scope.launch {
            val local = ensureIdentity() ?: return@launch
            val store = ensureTrustStore() ?: return@launch
            val info = localInfo(local)

            try {
                // Pairing accepts a peer we have not pinned yet; the window bounds it in time and
                // the human compares the code before anything is persisted.
                val transport = TlsClient.connect(
                    host = host,
                    port = port,
                    identity = local,
                    policy = PinPolicy.PAIRING_ONLY,
                    scope = scope
                )

                val runner = PairingRunner(
                    transport = transport,
                    local = PairingLocalInfo(
                        deviceId = info.deviceId,
                        name = info.name,
                        platform = info.platform,
                        capabilities = info.capabilities,
                        fingerprint = info.fingerprint
                    ),
                    role = PeerSession.Role.INITIATOR,
                    trustStore = store,
                    window = PairingWindow(),
                    peerHost = host,
                    peerPort = port
                )
                pairingRunner = runner

                scope.launch {
                    for (event in runner.events()) {
                        when (event) {
                            is PairingEvent.AwaitingConfirmation -> ConnectionRuntime.update {
                                it.copy(
                                    phase = ConnectionStatus.Phase.PAIRING,
                                    pairingCode = event.code,
                                    peerName = event.peerName
                                )
                            }

                            is PairingEvent.Paired -> {
                                ConnectionRuntime.update {
                                    it.copy(
                                        phase = ConnectionStatus.Phase.CONNECTED,
                                        peerName = event.peer.name,
                                        pairingCode = null,
                                        lastError = null
                                    )
                                }
                                updateNotification(getString(R.string.service_status_paired, event.peer.name))
                                // The Mac restarts its listener with the pinned policy once we are
                                // persisted, so give it a moment before dialling again.
                                kotlinx.coroutines.delay(PAIRING_RECONNECT_DELAY_MILLIS)
                                startConnecting()
                            }

                            is PairingEvent.Failed -> ConnectionRuntime.update {
                                it.copy(
                                    phase = ConnectionStatus.Phase.ERROR,
                                    pairingCode = null,
                                    lastError = event.reason.wireName
                                )
                            }
                        }
                    }
                }

                runner.run()
            } catch (error: Exception) {
                ConnectionRuntime.update {
                    it.copy(
                        phase = ConnectionStatus.Phase.ERROR,
                        lastError = error.message ?: getString(R.string.service_error_unreachable)
                    )
                }
            }
        }
    }

    // MARK: - Connecting

    private fun startConnecting() {
        connectionJob?.cancel()
        connectionJob = scope.launch {
            val local = ensureIdentity() ?: return@launch
            val store = ensureTrustStore() ?: return@launch
            val peer = store.allPeers().firstOrNull()
            val host = peer?.lastHost
            val port = peer?.lastPort

            if (host == null || port == null) {
                ConnectionRuntime.update {
                    it.copy(
                        phase = ConnectionStatus.Phase.ERROR,
                        lastError = getString(R.string.service_error_no_address)
                    )
                }
                return@launch
            }

            ConnectionRuntime.update {
                it.copy(phase = ConnectionStatus.Phase.CONNECTING, lastError = null)
            }

            // The stored address can go stale (USB tunnel dropped, DHCP change). A live mDNS
            // record for the same device is a better second guess than giving up.
            val currentlyDiscovered = ConnectionRuntime.discovered.value
            android.util.Log.i(
                TAG_CONNECT,
                "peer.deviceId=${peer.deviceId} discovered=${currentlyDiscovered.map { it.deviceId + "@" + it.host + ":" + it.port }}"
            )
            val targets = buildList {
                add(host to port)
                currentlyDiscovered
                    .firstOrNull { it.deviceId == peer.deviceId }
                    ?.let { found ->
                        if (found.host != host || found.port != port) add(found.host to found.port)
                    }
            }

            var lastError: Exception? = null
            var attemptedFallback = targets.size > 1
            var remainingTargets = targets
            var pollsLeft = 20

            while (true) {
                for ((targetHost, targetPort) in remainingTargets) {
                    try {
                        val established = connectAndRunSession(targetHost, targetPort, local, store)
                        if (established) return@launch
                        lastError = IllegalStateException(
                            "session to $targetHost:$targetPort closed before the handshake finished"
                        )
                    } catch (error: Exception) {
                        android.util.Log.w(
                            TAG_CONNECT,
                            "connect failed at $targetHost:$targetPort: ${error.javaClass.simpleName}: ${error.message}"
                        )
                        lastError = error
                    }
                }

                // mDNS can take a few seconds to resolve after the service (re)starts. Give it a
                // short window before reporting failure, rather than failing on the first dial.
                if (attemptedFallback || pollsLeft <= 0) break
                pollsLeft -= 1
                kotlinx.coroutines.delay(1_000)
                val found = ConnectionRuntime.discovered.value.firstOrNull { it.deviceId == peer.deviceId }
                if (found != null && (found.host != host || found.port != port)) {
                    remainingTargets = listOf(found.host to found.port)
                    attemptedFallback = true
                } else {
                    remainingTargets = emptyList()
                }
            }

            val error = lastError
            if (error != null) {
                ConnectionRuntime.update {
                    it.copy(
                        phase = ConnectionStatus.Phase.ERROR,
                        lastError = error.message ?: getString(R.string.service_error_failed)
                    )
                }
            }
        }
    }

    /** Dials a pinned peer and runs one session. Returns true once an established session closes. */
    private suspend fun connectAndRunSession(
        host: String,
        port: Int,
        local: DeviceIdentity,
        store: TrustStore
    ): Boolean {
        android.util.Log.i(TAG_CONNECT, "dialing pinned peer at $host:$port")
        val transport = TlsClient.connect(
            host = host,
            port = port,
            identity = local,
            policy = PinPolicy.pinned(store.allPeers()),
            scope = scope
        )
        android.util.Log.i(TAG_CONNECT, "tls handshake complete, starting session")

        var established = false
        try {
                val newSession = PeerSession(
                    transport = transport,
                    local = localInfo(local),
                    role = PeerSession.Role.INITIATOR
                )
                session = newSession
                ConnectionRuntime.attachSender { envelope ->
                    runCatching {
                        newSession.send(envelope)
                        true
                    }.getOrDefault(false)
                }
                fileReceiver = AndroidFileReceiver(
                    context = this,
                    send = { envelope -> ConnectionRuntime.send(envelope) },
                    onSaved = { name -> notifyFileSaved(name) }
                )

                scope.launch {
                    for (event in newSession.events()) {
                        when (event) {
                            is PeerSessionEvent.Established -> {
                                established = true
                                reconnectAttempt = 0
                                android.util.Log.i(TAG_CONNECT, "session established with ${event.info.name}")
                                ConnectionRuntime.update {
                                    it.copy(
                                        phase = ConnectionStatus.Phase.CONNECTED,
                                        peerName = event.info.name,
                                        lastError = null
                                    )
                                }
                                updateNotification(
                                    getString(R.string.service_status_connected, event.info.name)
                                )
                            }

                            is PeerSessionEvent.Message -> {
                                // Clipboard work belongs to the foreground UI; it is forwarded
                                // rather than handled here.
                                if (event.envelope.messageType == MessageType.CLIPBOARD_UPDATE ||
                                    event.envelope.messageType == MessageType.CLIPBOARD_ACK
                                ) {
                                    ConnectionRuntime.publishInbound(event.envelope)
                                } else if (event.envelope.messageType == MessageType.MIRROR_CHALLENGE) {
                                    mirrorProof.respond(event.envelope)?.let { ConnectionRuntime.send(it) }
                                } else if (event.envelope.messageType == MessageType.FILE_OFFER ||
                                    event.envelope.messageType == MessageType.FILE_CHUNK ||
                                    event.envelope.messageType == MessageType.FILE_COMPLETE
                                ) {
                                    fileReceiver?.handle(event.envelope)
                                }
                            }

                            is PeerSessionEvent.Closed -> {
                                android.util.Log.i(TAG_CONNECT, "session closed")
                                fileReceiver?.abort()
                                fileReceiver = null
                                ConnectionRuntime.detachSender()
                                session = null
                                ConnectionRuntime.update {
                                    it.copy(phase = ConnectionStatus.Phase.IDLE, peerName = null)
                                }
                                updateNotification(getString(R.string.service_status_closed))
                                // F04 / M4: trigger reconnect with backoff when the peer disconnects while the service is running.
                                if (connectionJob?.isActive != true) {
                                    val delaySecs = reconnectPolicy.delaySeconds(reconnectAttempt)
                                    reconnectAttempt = minOf(reconnectAttempt + 1, 10)
                                    android.util.Log.i(TAG_CONNECT, "scheduling reconnect in ${delaySecs}s")
                                    scope.launch {
                                        kotlinx.coroutines.delay((delaySecs * 1000).toLong())
                                        if (connectionJob?.isActive != true) {
                                            startConnecting()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

            newSession.run()
        } finally {
            ConnectionRuntime.detachSender()
            session = null
        }
        return established
    }

    // MARK: - Helpers

    /** Browses for Macs so the pairing screen can offer something to tap. */
    private fun startDiscovery() {
        if (discovery != null) return
        ensureTrustStore()
        runCatching {
            val nsd = NsdDiscovery(this)
            discovery = nsd
            nsd.browse(
                onPeer = { peer ->
                    val host = peer.host ?: return@browse
                    synchronized(discovered) {
                        discovered[peer.deviceId.hex] = DiscoveredEntry(
                            name = peer.name,
                            deviceId = peer.deviceId.hex,
                            host = host,
                            port = peer.port,
                            hostName = peer.hostName
                        )
                        ConnectionRuntime.setDiscovered(discovered.values.toList())
                    }
                    // M4 auto-connect: if idle/error and this peer is in trustStore, trigger reconnect
                    val currentPhase = ConnectionRuntime.status.value.phase
                    if (currentPhase == ConnectionStatus.Phase.IDLE || currentPhase == ConnectionStatus.Phase.ERROR) {
                        val isPaired = trustStore?.peer(peer.deviceId.hex) != null
                        if (isPaired && connectionJob?.isActive != true) {
                            android.util.Log.i(TAG_CONNECT, "mDNS found paired peer ${peer.name}, auto-connecting")
                            startConnecting()
                        }
                    }
                },
                onError = { message ->
                    ConnectionRuntime.update { it.copy(lastError = message) }
                }
            )
        }.onFailure {
            ConnectionRuntime.update { status ->
                status.copy(lastError = "discovery unavailable: ${it.message}")
            }
        }
    }

    private fun ensureIdentity(): DeviceIdentity? {
        identity?.let { return it }
        return runCatching {
            AndroidKeyStoreIdentities.loadOrCreate(deviceName()).also {
                identity = it
                ConnectionRuntime.update { status -> status.copy(identityShort = it.fingerprint.shortHex) }
            }
        }.onFailure {
            ConnectionRuntime.update { status ->
                status.copy(
                    phase = ConnectionStatus.Phase.ERROR,
                    lastError = getString(R.string.service_error_identity, it.message ?: "")
                )
            }
        }.getOrNull()
    }

    private fun ensureTrustStore(): TrustStore? {
        trustStore?.let { return it }
        return runCatching {
            EncryptedTrustStore(
                prefs = getSharedPreferences(PREFS_TRUST, Context.MODE_PRIVATE),
                secretBox = KeystoreSecretBox()
            ).also { trustStore = it }
        }.getOrNull()
    }

    private fun localInfo(identity: DeviceIdentity) = LocalDeviceInfo(
        deviceId = DeviceId.parse(deviceIdHex()) ?: DeviceId.random(),
        name = deviceName(),
        platform = Platform.ANDROID,
        appVersion = BuildConfig.VERSION_NAME,
        capabilities = listOf(Capability.CLIPBOARD, Capability.PRESENCE),
        fingerprint = identity.fingerprint
    )

    private fun deviceIdHex(): String {
        val prefs = getSharedPreferences(PREFS_DEVICE, Context.MODE_PRIVATE)
        prefs.getString(KEY_DEVICE_ID, null)?.let { return it }
        val generated = DeviceId.random().hex
        prefs.edit().putString(KEY_DEVICE_ID, generated).apply()
        return generated
    }

    private fun deviceName(): String =
        (android.os.Build.MODEL ?: "Android").take(MAX_DEVICE_NAME_CHARS)

    private fun shutdown() {
        connectionJob?.cancel()
        discovery?.stopBrowsing()
        discovery = null
        synchronized(discovered) {
            discovered.clear()
            ConnectionRuntime.setDiscovered(emptyList())
        }
        pairingRunner = null
        session = null
        ConnectionRuntime.detachSender()
        ConnectionRuntime.update {
            it.copy(
                serviceRunning = false,
                phase = ConnectionStatus.Phase.STOPPED,
                peerName = null,
                pairingCode = null
            )
        }
        scope.cancel()
    }

    // MARK: - Notification

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.service_channel_name),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = getString(R.string.service_channel_description)
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_klyndro_mark)
            .setContentIntent(open)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    /** Shown when a file from the Mac has been verified and saved. Names the file, never its content. */
    private fun notifyFileSaved(displayName: String) {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.file_received_title))
            .setContentText(getString(R.string.file_received_body, displayName))
            .setSmallIcon(R.drawable.ic_klyndro_mark)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        manager.notify(FILE_NOTIFICATION_ID, notification)
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification(text))
    }

    companion object {
        const val ACTION_PAIR = "id.my.wandidev.klyndro.action.PAIR"
        const val ACTION_CONNECT = "id.my.wandidev.klyndro.action.CONNECT"
        const val ACTION_STOP = "id.my.wandidev.klyndro.action.STOP"
        const val EXTRA_HOST = "host"
        const val EXTRA_PORT = "port"
        const val EXTRA_HOSTNAME = "hostname"

        private const val CHANNEL_ID = "klyndro-connection"
        private const val NOTIFICATION_ID = 1
        private const val FILE_NOTIFICATION_ID = 2
        private const val PREFS_DEVICE = "klyndro_device"
        private const val PREFS_TRUST = "klyndro_trust"
        private const val KEY_DEVICE_ID = "device_id"
        private const val MAX_DEVICE_NAME_CHARS = 64
        private const val PAIRING_RECONNECT_DELAY_MILLIS = 800L
        private const val TAG_CONNECT = "KlyndroConnect"

        fun intent(context: Context, action: String): Intent =
            Intent(context, KlyndroService::class.java).setAction(action)

        fun pairIntent(context: Context, host: String, port: Int, hostName: String?): Intent =
            intent(context, ACTION_PAIR)
                .putExtra(EXTRA_HOST, host)
                .putExtra(EXTRA_PORT, port)
                .putExtra(EXTRA_HOSTNAME, hostName)

        /**
         * NSD often resolves a Mac to an IPv6 link-local address with an interface zone, which is
         * not reachable across devices. Ask the resolver for an IPv4 address and fall back to the
         * advertised one.
         */
        fun preferReachableAddress(host: String, hostName: String?): String {
            if (!host.contains(":")) return host
            val resolved = runCatching {
                java.net.InetAddress.getAllByName(hostName ?: host)
            }.getOrNull() ?: return host
            return resolved
                .firstOrNull { it is java.net.Inet4Address }
                ?.hostAddress
                ?: host
        }
    }
}
