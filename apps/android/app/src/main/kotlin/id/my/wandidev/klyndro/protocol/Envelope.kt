package id.my.wandidev.klyndro.protocol

import com.google.gson.JsonObject

/** Message types known to this implementation, Klyndro Protocol v1 §5. */
enum class MessageType(val wireName: String?) {
    HELLO("hello"),
    HELLO_ACK("hello.ack"),
    PING("ping"),
    PONG("pong"),
    CLIPBOARD_UPDATE("clipboard.update"),
    CLIPBOARD_ACK("clipboard.ack"),
    NOTIFICATION_POST("notification.post"),
    FILE_OFFER("file.offer"),
    FILE_ACCEPT("file.accept"),
    FILE_REJECT("file.reject"),
    FILE_CHUNK("file.chunk"),
    FILE_COMPLETE("file.complete"),
    PAIR_REQUEST("pair.request"),
    PAIR_CONFIRM("pair.confirm"),
    PAIR_RESULT("pair.result"),
    ERROR("error"),
    UNKNOWN(null);

    val isKnown: Boolean get() = this != UNKNOWN

    companion object {
        /** Unknown names map to [UNKNOWN] and must be ignored, not rejected (§5). */
        fun fromWire(name: String): MessageType =
            entries.firstOrNull { it.wireName == name } ?: UNKNOWN
    }
}

/** Envelope, Klyndro Protocol v1 §4. */
data class Envelope(
    val v: Int,
    val id: String,
    val type: String,
    val ts: Long,
    val body: JsonObject?
) {
    val messageType: MessageType get() = MessageType.fromWire(type)

    companion object {
        const val CURRENT_VERSION = 1

        fun create(
            type: MessageType,
            body: JsonObject? = null,
            now: Long = System.currentTimeMillis()
        ): Envelope = Envelope(
            v = CURRENT_VERSION,
            id = java.util.UUID.randomUUID().toString().lowercase(),
            type = requireNotNull(type.wireName) { "unknown message types cannot be created" },
            ts = now,
            body = body
        )
    }
}
