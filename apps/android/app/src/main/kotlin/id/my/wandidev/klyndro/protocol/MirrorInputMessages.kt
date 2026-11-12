package id.my.wandidev.klyndro.protocol

import com.google.gson.JsonArray
import com.google.gson.JsonObject

enum class InputGestureKind(val wireName: String) {
    TAP("tap"),
    LONG_PRESS("long_press"),
    SWIPE("swipe");

    companion object {
        fun fromWire(name: String): InputGestureKind? =
            entries.firstOrNull { it.wireName == name }
    }
}

data class InputGestureBody(
    val kind: InputGestureKind,
    val x: Float,
    val y: Float,
    val endX: Float? = null,
    val endY: Float? = null,
    val durationMs: Int = defaultDuration(kind)
) {
    fun toEnvelope(): Envelope = Envelope.create(
        MessageType.INPUT_GESTURE,
        JsonObject().apply {
            addProperty("kind", kind.wireName)
            addProperty("x", x)
            addProperty("y", y)
            if (endX != null && endY != null) {
                addProperty("end_x", endX)
                addProperty("end_y", endY)
            }
            addProperty("duration_ms", durationMs)
        }
    )

    companion object {
        private val DURATION_RANGE = 1..5000

        fun defaultDuration(kind: InputGestureKind): Int = when (kind) {
            InputGestureKind.TAP -> 50
            InputGestureKind.LONG_PRESS -> 600
            InputGestureKind.SWIPE -> 220
        }

        fun decode(envelope: Envelope): InputGestureBody? {
            if (envelope.messageType != MessageType.INPUT_GESTURE) return null
            val body = envelope.body ?: return null
            val kind = body.get("kind")?.takeIf { it.isJsonPrimitive }?.asString
                ?.let { InputGestureKind.fromWire(it) } ?: return null
            val x = normalizedFloat(body, "x") ?: return null
            val y = normalizedFloat(body, "y") ?: return null
            val duration = body.get("duration_ms")?.takeIf { it.isJsonPrimitive }?.asInt ?: return null
            if (duration !in DURATION_RANGE) return null

            if (kind == InputGestureKind.SWIPE) {
                val endX = normalizedFloat(body, "end_x") ?: return null
                val endY = normalizedFloat(body, "end_y") ?: return null
                return InputGestureBody(kind, x, y, endX, endY, duration)
            }
            return InputGestureBody(kind, x, y, null, null, duration)
        }

        private fun normalizedFloat(body: JsonObject, key: String): Float? {
            val value = body.get(key)?.takeIf { it.isJsonPrimitive }?.asDouble ?: return null
            if (!value.isFinite() || value < 0.0 || value > 1.0) return null
            return value.toFloat()
        }
    }
}

enum class InputActionKind(val wireName: String) {
    BACK("back"),
    HOME("home"),
    RECENTS("recents"),
    NOTIFICATIONS("notifications"),
    LOCK_SCREEN("lock_screen");

    companion object {
        fun fromWire(name: String): InputActionKind? =
            entries.firstOrNull { it.wireName == name }
    }
}

data class InputActionBody(val action: InputActionKind) {
    fun toEnvelope(): Envelope = Envelope.create(
        MessageType.INPUT_ACTION,
        JsonObject().apply { addProperty("action", action.wireName) }
    )

    companion object {
        fun decode(envelope: Envelope): InputActionBody? {
            if (envelope.messageType != MessageType.INPUT_ACTION) return null
            val body = envelope.body ?: return null
            val action = body.get("action")?.takeIf { it.isJsonPrimitive }?.asString
                ?.let { InputActionKind.fromWire(it) } ?: return null
            return InputActionBody(action)
        }
    }
}

enum class InputTextMode(val wireName: String) {
    APPEND("append"),
    REPLACE("replace"),
    BACKSPACE("backspace");

    companion object {
        fun fromWire(name: String): InputTextMode? =
            entries.firstOrNull { it.wireName == name }
    }
}

data class InputTextBody(
    val mode: InputTextMode = InputTextMode.APPEND,
    val text: String = ""
) {
    fun toEnvelope(): Envelope = Envelope.create(
        MessageType.INPUT_TEXT,
        JsonObject().apply {
            addProperty("mode", mode.wireName)
            addProperty("text", text)
        }
    )

    companion object {
        const val MAX_UTF8_BYTES = 4096

        fun decode(envelope: Envelope): InputTextBody? {
            if (envelope.messageType != MessageType.INPUT_TEXT) return null
            val body = envelope.body ?: return null
            val mode = body.get("mode")?.takeIf { it.isJsonPrimitive }?.asString
                ?.let { InputTextMode.fromWire(it) } ?: return null
            val text = body.get("text")?.takeIf { it.isJsonPrimitive }?.asString ?: return null
            if (text.toByteArray(Charsets.UTF_8).size > MAX_UTF8_BYTES) return null
            if (mode != InputTextMode.BACKSPACE && text.isEmpty()) return null
            return InputTextBody(mode, text)
        }
    }
}

data class StandardAppEntry(
    val packageName: String,
    val label: String
)

object AppLauncherMessages {
    const val MAX_APPS = 500
    private const val MAX_LABEL_CHARS = 128

    fun isValidPackageName(raw: String): Boolean {
        val trimmed = raw.trim()
        if (trimmed.isEmpty() || trimmed.length > 255 || trimmed.startsWith("-")) return false
        val segments = trimmed.split('.')
        if (segments.size < 2) return false
        return segments.all { seg ->
            seg.isNotEmpty() && seg.all { ch -> ch in 'a'..'z' || ch in 'A'..'Z' || ch in '0'..'9' || ch == '_' }
        }
    }

    fun listEnvelope(apps: List<StandardAppEntry>): Envelope {
        val arr = JsonArray()
        apps.take(MAX_APPS).forEach { app ->
            if (isValidPackageName(app.packageName) && app.label.isNotBlank()) {
                arr.add(
                    JsonObject().apply {
                        addProperty("package", app.packageName)
                        addProperty("label", app.label.trim().take(MAX_LABEL_CHARS))
                    }
                )
            }
        }
        return Envelope.create(
            MessageType.APP_LIST,
            JsonObject().apply { add("apps", arr) }
        )
    }

    fun decodeLaunch(envelope: Envelope): String? {
        if (envelope.messageType != MessageType.APP_LAUNCH) return null
        val pkg = envelope.body?.get("package")?.takeIf { it.isJsonPrimitive }?.asString ?: return null
        return pkg.trim().takeIf { isValidPackageName(it) }
    }
}
