package id.my.wandidev.klyndro.clipboard

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * The device clipboard, with the platform restrictions made explicit.
 *
 * Android 10+ only allows the focused app or the active IME to read *or write* the clipboard.
 * `isUsable()` therefore reports whether the app is currently in a position to use it, so callers
 * can tell "clipboard sync is broken" apart from "Android does not allow it right now".
 *
 * A foreground service does **not** satisfy that rule. See docs/architecture/clipboard.md.
 */
class AndroidClipboard(private val context: Context) {

    private val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private var listener: ClipboardManager.OnPrimaryClipChangedListener? = null
    private var changeCount = 0
    /**
     * Last text observed. `ClipboardManager` exposes no change counter, so one is derived from
     * actual content changes; incrementing on every read would make every poll look like a copy.
     */
    private var lastSeenText: String? = null

    /** True when the app currently holds the clipboard. */
    var hasAccess: Boolean = false
        private set

    /** Reads the clipboard, or `null` when there is no text or access is refused. */
    fun read(): ClipboardSnapshot? {
        val clip = try {
            manager.primaryClip
        } catch (_: SecurityException) {
            hasAccess = false
            return null
        } ?: return null

        hasAccess = true

        if (clip.itemCount == 0) return null
        val item = clip.getItemAt(0)
        val text = item.text?.toString() ?: item.coerceToText(context)?.toString() ?: return null
        if (text.isEmpty()) return null

        if (text != lastSeenText) {
            lastSeenText = text
            changeCount += 1
        }

        return ClipboardSnapshot(
            text = text,
            sensitive = isSensitive(clip.description),
            changeCount = changeCount
        )
    }

    /** Writes text to the clipboard. Returns false when the platform refuses. */
    fun write(text: String): Boolean {
        return try {
            manager.setPrimaryClip(ClipData.newPlainText(LABEL, text))
            hasAccess = true
            // Record our own write as already seen, so the listener firing for it does not look
            // like a fresh copy. The engine's hash check is the real loop guard.
            if (text != lastSeenText) {
                lastSeenText = text
                changeCount += 1
            }
            true
        } catch (_: SecurityException) {
            hasAccess = false
            false
        }
    }

    /**
     * Observes clipboard changes.
     *
     * This only fires while the app can access the clipboard. It is not a background hook, and the
     * UI says so rather than implying the phone is always syncing.
     */
    fun startObserving(onChanged: () -> Unit) {
        stopObserving()
        val newListener = ClipboardManager.OnPrimaryClipChangedListener {
            mainHandler.post { onChanged() }
        }
        listener = newListener
        manager.addPrimaryClipChangedListener(newListener)
    }

    fun stopObserving() {
        listener?.let { manager.removePrimaryClipChangedListener(it) }
        listener = null
    }

    /** Whether the current primary clip is flagged sensitive (API 33+, plus the older extra). */
    fun isCurrentClipSensitive(): Boolean {
        val clip = runCatching { manager.primaryClip }.getOrNull() ?: return false
        return isSensitive(clip.description)
    }

    companion object {
        private const val LABEL = "Klyndro"

        fun isSensitive(description: ClipDescription?): Boolean {
            if (description == null) return false
            // EXTRA_IS_SENSITIVE has been readable via the description's extras since API 33.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val extras = description.extras
                if (extras != null && extras.containsKey(ClipDescription.EXTRA_IS_SENSITIVE)) {
                    return extras.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE, false)
                }
            }
            return false
        }
    }
}
