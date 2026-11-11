package id.my.wandidev.klyndro.clipboard

import id.my.wandidev.klyndro.protocol.ClipboardContentType
import id.my.wandidev.klyndro.protocol.ClipboardMessageCodec
import id.my.wandidev.klyndro.protocol.ClipboardUpdateBody
import id.my.wandidev.klyndro.protocol.DeviceId

/** A snapshot of the local clipboard. */
data class ClipboardSnapshot(val text: String, val sensitive: Boolean, val changeCount: Int)

/** What the engine decided to do with an outbound change. */
sealed interface ClipboardOutbound {
    data class Send(val body: ClipboardUpdateBody) : ClipboardOutbound
    data class Suppress(val reason: ClipboardSuppressionReason) : ClipboardOutbound
}

enum class ClipboardSuppressionReason {
    DISABLED,
    EMPTY,
    DUPLICATE,
    ECHO_OF_REMOTE,
    SENSITIVE,
    TOO_LARGE
}

/** What the engine decided to do with inbound content. */
sealed interface ClipboardInbound {
    data class Apply(val text: String) : ClipboardInbound
    data class Ignore(val reason: ClipboardIgnoreReason) : ClipboardInbound
}

enum class ClipboardIgnoreReason {
    OWN_ORIGIN,
    DUPLICATE,
    STALE,
    DISABLED,
    UNSUPPORTED_TYPE,
    SENSITIVE
}

/**
 * Decides what crosses the clipboard boundary. Pure logic: no clipboard, no sockets.
 *
 * Mirrors the Swift `ClipboardSyncEngine`, including the three independent loop-prevention rules:
 *
 * 1. `originId` — never re-send content this device originated.
 * 2. `lastAppliedRemoteHash` within a short window — that change *is* our own write.
 * 3. `lastSeenHash` — whatever the clipboard currently holds is never sent back, whoever put it
 *    there. This is what ends the loop even when the clipboard reports our write late.
 */
class ClipboardSyncEngine(
    val deviceId: DeviceId,
    var isEnabled: Boolean = true,
    var allowsSensitive: Boolean = false
) {
    private var changeCounter = 0
    private var lastSeenHash: String? = null
    private var lastAppliedRemoteHash: String? = null
    private var lastAppliedAtMillis: Long? = null
    private val lastAppliedCounterByOrigin = mutableMapOf<String, Int>()
    private var lastLocalChangeCount: Int? = null

    /** For tests and diagnostics. */
    val currentChangeCounter: Int get() = changeCounter

    /** Evaluates a local clipboard snapshot. */
    fun outbound(
        snapshot: ClipboardSnapshot,
        nowMillis: Long = System.currentTimeMillis()
    ): ClipboardOutbound {
        if (!isEnabled) return ClipboardOutbound.Suppress(ClipboardSuppressionReason.DISABLED)

        if (lastLocalChangeCount == snapshot.changeCount) {
            return ClipboardOutbound.Suppress(ClipboardSuppressionReason.DUPLICATE)
        }
        lastLocalChangeCount = snapshot.changeCount

        val text = snapshot.text
        if (text.isEmpty()) return ClipboardOutbound.Suppress(ClipboardSuppressionReason.EMPTY)

        val byteCount = text.toByteArray(Charsets.UTF_8).size
        if (byteCount > ClipboardMessageCodec.MAXIMUM_TEXT_BYTES) {
            return ClipboardOutbound.Suppress(ClipboardSuppressionReason.TOO_LARGE)
        }

        if (snapshot.sensitive && !allowsSensitive) {
            return ClipboardOutbound.Suppress(ClipboardSuppressionReason.SENSITIVE)
        }

        val hash = ClipboardMessageCodec.hashOf(text)

        val appliedAt = lastAppliedAtMillis
        if (appliedAt != null &&
            lastAppliedRemoteHash == hash &&
            nowMillis - appliedAt <= ECHO_SUPPRESSION_WINDOW_MILLIS
        ) {
            return ClipboardOutbound.Suppress(ClipboardSuppressionReason.ECHO_OF_REMOTE)
        }

        if (hash == lastSeenHash) {
            return ClipboardOutbound.Suppress(ClipboardSuppressionReason.DUPLICATE)
        }

        lastSeenHash = hash
        changeCounter += 1

        return ClipboardOutbound.Send(
            ClipboardUpdateBody(
                contentType = ClipboardContentType.PLAIN_TEXT,
                text = text,
                hash = hash,
                changeCount = changeCounter,
                originId = deviceId,
                sensitive = snapshot.sensitive
            )
        )
    }

    /**
     * Builds an update for text the user typed explicitly, without touching the clipboard.
     *
     * Android's clipboard rules make the typed-text path the only one that always works, so it is
     * a first-class way to send rather than a testing hook. Every safety rule still applies.
     */
    fun explicitOutbound(
        text: String,
        sensitive: Boolean = false,
        nowMillis: Long = System.currentTimeMillis()
    ): ClipboardOutbound {
        if (!isEnabled) return ClipboardOutbound.Suppress(ClipboardSuppressionReason.DISABLED)
        if (text.isEmpty()) return ClipboardOutbound.Suppress(ClipboardSuppressionReason.EMPTY)

        val byteCount = text.toByteArray(Charsets.UTF_8).size
        if (byteCount > ClipboardMessageCodec.MAXIMUM_TEXT_BYTES) {
            return ClipboardOutbound.Suppress(ClipboardSuppressionReason.TOO_LARGE)
        }
        if (sensitive && !allowsSensitive) {
            return ClipboardOutbound.Suppress(ClipboardSuppressionReason.SENSITIVE)
        }

        val hash = ClipboardMessageCodec.hashOf(text)
        val appliedAt = lastAppliedAtMillis
        if (appliedAt != null && lastAppliedRemoteHash == hash &&
            nowMillis - appliedAt <= ECHO_SUPPRESSION_WINDOW_MILLIS
        ) {
            return ClipboardOutbound.Suppress(ClipboardSuppressionReason.ECHO_OF_REMOTE)
        }
        if (hash == lastSeenHash) {
            return ClipboardOutbound.Suppress(ClipboardSuppressionReason.DUPLICATE)
        }

        lastSeenHash = hash
        changeCounter += 1
        return ClipboardOutbound.Send(
            ClipboardUpdateBody(
                contentType = ClipboardContentType.PLAIN_TEXT,
                text = text,
                hash = hash,
                changeCount = changeCounter,
                originId = deviceId,
                sensitive = sensitive
            )
        )
    }

    /** Decides whether inbound content should be written to the local clipboard. */
    fun inbound(
        body: ClipboardUpdateBody,
        nowMillis: Long = System.currentTimeMillis()
    ): ClipboardInbound {
        if (!isEnabled) return ClipboardInbound.Ignore(ClipboardIgnoreReason.DISABLED)
        if (body.contentType != ClipboardContentType.PLAIN_TEXT) {
            return ClipboardInbound.Ignore(ClipboardIgnoreReason.UNSUPPORTED_TYPE)
        }
        if (body.originId == deviceId) {
            return ClipboardInbound.Ignore(ClipboardIgnoreReason.OWN_ORIGIN)
        }
        if (body.sensitive && !allowsSensitive) {
            return ClipboardInbound.Ignore(ClipboardIgnoreReason.SENSITIVE)
        }

        val lastCounter = lastAppliedCounterByOrigin[body.originId.hex]
        if (lastCounter != null && body.changeCount <= lastCounter) {
            return ClipboardInbound.Ignore(ClipboardIgnoreReason.STALE)
        }

        if (body.hash == lastAppliedRemoteHash) {
            return ClipboardInbound.Ignore(ClipboardIgnoreReason.DUPLICATE)
        }

        recordApplied(body, nowMillis)
        return ClipboardInbound.Apply(body.text)
    }

    /** Records a write of remote content so the resulting local change is recognised as an echo. */
    fun noteApplied(body: ClipboardUpdateBody, nowMillis: Long = System.currentTimeMillis()) {
        recordApplied(body, nowMillis)
    }

    /** Called on reconnect: per-origin counters are session state, not history. */
    fun resetSessionState() {
        lastAppliedCounterByOrigin.clear()
        lastAppliedRemoteHash = null
        lastAppliedAtMillis = null
        lastLocalChangeCount = null
        // `lastSeenHash` and `changeCounter` survive: they describe what the clipboard holds and
        // what this device produced, so a reconnect does not immediately re-send it.
    }

    private fun recordApplied(body: ClipboardUpdateBody, nowMillis: Long) {
        lastAppliedRemoteHash = body.hash
        lastAppliedAtMillis = nowMillis
        lastSeenHash = body.hash
        lastAppliedCounterByOrigin[body.originId.hex] = body.changeCount
    }

    companion object {
        /** Window in which a local change matching applied remote content is treated as our echo. */
        const val ECHO_SUPPRESSION_WINDOW_MILLIS = 2_000L
    }
}
