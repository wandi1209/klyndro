package id.my.wandidev.klyndro.ui

import android.app.Application
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import id.my.wandidev.klyndro.clipboard.AndroidClipboard
import id.my.wandidev.klyndro.clipboard.ClipboardInbound
import id.my.wandidev.klyndro.clipboard.ClipboardOutbound
import id.my.wandidev.klyndro.clipboard.ClipboardSyncEngine
import id.my.wandidev.klyndro.connection.ConnectionRuntime
import id.my.wandidev.klyndro.connection.ConnectionStatus
import id.my.wandidev.klyndro.connection.DiscoveredEntry
import id.my.wandidev.klyndro.protocol.ClipboardMessageCodec
import id.my.wandidev.klyndro.protocol.ClipboardRejectReason
import id.my.wandidev.klyndro.protocol.ClipboardAckBody
import id.my.wandidev.klyndro.protocol.DeviceId
import id.my.wandidev.klyndro.protocol.Envelope
import id.my.wandidev.klyndro.protocol.MessageType
import id.my.wandidev.klyndro.service.KlyndroService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * View state for the app shell.
 *
 * Clipboard sync lives here, not in the service, because Android only allows clipboard access to a
 * focused app. The polling job runs only while the Activity is resumed *and* a session exists, so
 * an idle Klyndro does no work.
 */
class KlyndroViewModel(application: Application) : AndroidViewModel(application) {

    private val prefs = application.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
    private val clipboard = AndroidClipboard(application)

    var clipboardSyncEnabled by mutableStateOf(prefs.getBoolean(KEY_CLIPBOARD_SYNC, true))
        private set

    var notificationsEnabled by mutableStateOf(prefs.getBoolean(KEY_NOTIFICATIONS, false))
        private set

    /** Result of an explicit clipboard action, for immediate feedback. */
    var clipboardActionMessage by mutableStateOf<String?>(null)
        private set

    fun sendFileUri(uri: android.net.Uri) {
        val context = getApplication<Application>()
        viewModelScope.launch {
            clipboardActionMessage = "Sending file to Mac…"
            val res = id.my.wandidev.klyndro.filetransfer.AndroidFileSender.sendUri(context, uri)
            res.onSuccess { name ->
                clipboardActionMessage = "File sent: $name"
            }.onFailure { err ->
                clipboardActionMessage = "File send failed: ${err.message}"
            }
        }
    }

    /**
     * What Klyndro last saw in the clipboard.
     *
     * Shown only in the app, truncated, and never logged: users need to see *why* a copy did or did
     * not travel, and "it did nothing" is the least helpful possible failure.
     */
    var clipboardPreview by mutableStateOf<String?>(null)
        private set

    val applicationId: String = application.packageName

    val versionName: String = runCatching {
        @Suppress("DEPRECATION")
        application.packageManager.getPackageInfo(application.packageName, 0).versionName
    }.getOrNull() ?: "unknown"

    /**
     * Short form of this device's pinned fingerprint.
     *
     * Loading the identity touches the Android Keystore, which is unavailable on the JVM, so a
     * failure degrades to `null` rather than breaking the screen.
     */
    val identityFingerprint: String? by lazy {
        runCatching {
            id.my.wandidev.klyndro.crypto.AndroidKeyStoreIdentities
                .loadOrCreate("Klyndro Android")
                .fingerprint
                .shortHex
        }.getOrNull()
    }

    val status: StateFlow<ConnectionStatus> = ConnectionRuntime.status
    val discovered: StateFlow<List<DiscoveredEntry>> = ConnectionRuntime.discovered

    private var engine: ClipboardSyncEngine? = null
    private var pollJob: Job? = null
    private var inboundJob: Job? = null

    private val deviceId: DeviceId by lazy {
        val stored = prefs.getString(KEY_DEVICE_ID, null)
        DeviceId.parse(stored ?: "") ?: DeviceId.random().also {
            prefs.edit().putString(KEY_DEVICE_ID, it.hex).apply()
        }
    }

    init {
        inboundJob = viewModelScope.launch {
            ConnectionRuntime.inbound.collect { envelope -> handleInbound(envelope) }
        }
    }

    // MARK: - Preferences

    fun updateClipboardSyncEnabled(enabled: Boolean) {
        clipboardSyncEnabled = enabled
        prefs.edit().putBoolean(KEY_CLIPBOARD_SYNC, enabled).apply()
        engine?.isEnabled = enabled
        if (!enabled) stopClipboardLoop()
    }

    fun updateNotificationsEnabled(enabled: Boolean) {
        notificationsEnabled = enabled
        prefs.edit().putBoolean(KEY_NOTIFICATIONS, enabled).apply()
    }

    // MARK: - Lifecycle

    /** Called when the Activity becomes visible: the only time Android lets us touch the clipboard. */
    fun onResumed() {
        // M4: automatically start the connection service when the user opens the app
        if (!status.value.serviceRunning) {
            startService()
        }
        ensureEngine()
        refreshClipboardPreview()
        startClipboardLoop()
    }

    /** Reads the clipboard once, for the in-app preview. */
    fun refreshClipboardPreview() {
        val snapshot = clipboard.read()
        clipboardPreview = snapshot?.text?.let { preview(it) }
    }

    private fun preview(text: String): String {
        val singleLine = text.replace('\n', ' ').replace('\r', ' ')
        return if (singleLine.length <= PREVIEW_CHARS) singleLine
        else singleLine.take(PREVIEW_CHARS) + "…"
    }

    fun onPaused() {
        stopClipboardLoop()
    }

    /** Starts the foreground service so the connection survives leaving the app. */
    fun startService() {
        val context = getApplication<Application>()
        context.startForegroundService(KlyndroService.intent(context, KlyndroService.ACTION_CONNECT))
    }

    fun stopService() {
        val context = getApplication<Application>()
        context.startService(
            KlyndroService.intent(context, KlyndroService.ACTION_STOP)
        )
    }

    fun pair(host: String, port: Int, hostName: String? = null) {
        val context = getApplication<Application>()
        context.startForegroundService(KlyndroService.pairIntent(context, host, port, hostName))
    }

    fun confirmPairing(confirmed: Boolean) {
        ConnectionRuntime.pairingDecisions.trySend(confirmed)
        if (!confirmed) ConnectionRuntime.clearPairingCode()
    }

    fun clearClipboardActionMessage() {
        clipboardActionMessage = null
    }

    // MARK: - Clipboard

    /** Sends the current clipboard on demand, for the explicit "send" affordance. */
    fun sendClipboardNow() {
        val context = getApplication<Application>()
        val snapshot = clipboard.read()
        if (snapshot == null) {
            clipboardActionMessage = if (clipboard.hasAccess) {
                context.getString(id.my.wandidev.klyndro.R.string.clipboard_nothing_to_send)
            } else {
                context.getString(id.my.wandidev.klyndro.R.string.clipboard_read_failed)
            }
            return
        }
        viewModelScope.launch { sendSnapshot(snapshot) }
    }

    /** Sends user-typed text without touching the clipboard, which Android restricts. */
    fun sendTextToMac(text: String) {
        val currentEngine = engine ?: ensureEngine().let { engine!! }
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return

        when (val decision = currentEngine.explicitOutbound(trimmed)) {
            is ClipboardOutbound.Suppress -> clipboardActionMessage =
                "Not sent: ${decision.reason.name.lowercase().replace('_', ' ')}"
            is ClipboardOutbound.Send -> viewModelScope.launch {
                val sent = ConnectionRuntime.send(
                    ClipboardMessageCodec.updateEnvelope(decision.body)
                )
                if (sent) {
                    val status = status.value
                    ConnectionRuntime.noteClipboardCounts(
                        sent = status.clipboardSentCount + 1,
                        applied = status.clipboardAppliedCount
                    )
                    clipboardActionMessage = "Sent to Mac"
                } else {
                    clipboardActionMessage = "Not connected"
                }
            }
        }
    }

    private fun ensureEngine() {
        if (engine != null) return
        engine = ClipboardSyncEngine(
            deviceId = deviceId,
            isEnabled = clipboardSyncEnabled,
            allowsSensitive = false
        )
    }

    private fun startClipboardLoop() {
        val currentEngine = engine ?: return
        if (!clipboardSyncEnabled || pollJob != null) return
        if (status.value.phase != ConnectionStatus.Phase.CONNECTED) return

        currentEngine.resetSessionState()

        pollJob = viewModelScope.launch(Dispatchers.Default) {
            while (isActive) {
                delay(POLL_INTERVAL_MILLIS)
                if (!isActive) break
                if (status.value.phase != ConnectionStatus.Phase.CONNECTED) continue

                val snapshot = clipboard.read() ?: continue
                sendSnapshot(snapshot)
            }
        }
    }

    private fun stopClipboardLoop() {
        pollJob?.cancel()
        pollJob = null
    }

    private suspend fun sendSnapshot(snapshot: id.my.wandidev.klyndro.clipboard.ClipboardSnapshot) {
        val currentEngine = engine ?: return
        when (val decision = currentEngine.outbound(snapshot)) {
            is ClipboardOutbound.Suppress -> Unit
            is ClipboardOutbound.Send -> {
                val sent = ConnectionRuntime.send(
                    ClipboardMessageCodec.updateEnvelope(decision.body)
                )
                if (!sent) return
                val status = status.value
                ConnectionRuntime.noteClipboardCounts(
                    sent = status.clipboardSentCount + 1,
                    applied = status.clipboardAppliedCount
                )
            }
        }
    }

    private suspend fun handleInbound(envelope: Envelope) {
        val currentEngine = engine ?: return

        when (envelope.messageType) {
            MessageType.CLIPBOARD_UPDATE -> {
                val body = runCatching { ClipboardMessageCodec.decodeUpdate(envelope) }.getOrNull()
                    ?: return

                when (val decision = currentEngine.inbound(body)) {
                    is ClipboardInbound.Apply -> {
                        val written = clipboard.write(decision.text)
                        clipboardPreview = preview(decision.text)
                        if (written) {
                            currentEngine.noteApplied(body)
                            val status = status.value
                            ConnectionRuntime.noteClipboardCounts(
                                sent = status.clipboardSentCount,
                                applied = status.clipboardAppliedCount + 1
                            )
                        }
                    }

                    is ClipboardInbound.Ignore -> Unit
                }
            }

            MessageType.CLIPBOARD_ACK -> Unit

            else -> Unit
        }
    }

    override fun onCleared() {
        stopClipboardLoop()
        inboundJob?.cancel()
        super.onCleared()
    }

    private companion object {
        const val PREFERENCES_NAME = "klyndro_preferences"
        const val KEY_CLIPBOARD_SYNC = "clipboard_sync_enabled"
        const val KEY_NOTIFICATIONS = "notifications_enabled"
        const val KEY_DEVICE_ID = "view_device_id"
        const val POLL_INTERVAL_MILLIS = 700L
        const val PREVIEW_CHARS = 120
    }
}
