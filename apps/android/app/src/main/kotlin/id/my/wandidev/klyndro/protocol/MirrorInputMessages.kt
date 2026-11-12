package id.my.wandidev.klyndro.protocol

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
