package id.my.wandidev.klyndro.protocol

import com.google.gson.JsonObject
import id.my.wandidev.klyndro.crypto.Fingerprint
import java.security.MessageDigest

/** Clipboard content type. v1 carries UTF-8 text only (protocol §5.2). */
enum class ClipboardContentType(val wireName: String) {
    PLAIN_TEXT("text/plain");

    companion object {
        fun fromWire(value: String): ClipboardContentType? = entries.firstOrNull { it.wireName == value }
    }
}

/** Body of `clipboard.update` (protocol §5.2). */
data class ClipboardUpdateBody(
    val contentType: ClipboardContentType,
    val text: String,
    /** Lowercase hex SHA-256 of the UTF-8 text. Loop and duplicate suppression depends on it. */
    val hash: String,
    /** Sender's monotonic counter, used to reject stale updates after a reconnect. */
    val changeCount: Int,
    /** Device that first produced this content. */
    val originId: DeviceId,
    val sensitive: Boolean
) {
    fun toJson(): JsonObject = JsonObject().apply {
        addProperty("content_type", contentType.wireName)
        addProperty("text", text)
        addProperty("hash", hash)
        addProperty("change_count", changeCount)
        addProperty("origin_id", originId.hex)
        addProperty("sensitive", sensitive)
    }
}

/** Why a receiver refused clipboard content. */
enum class ClipboardRejectReason(val wireName: String) {
    TOO_LARGE("too_large"),
    UNSUPPORTED_TYPE("unsupported_type"),
    DISABLED("disabled"),
    SENSITIVE("sensitive");

    companion object {
        fun fromWire(value: String): ClipboardRejectReason? =
            entries.firstOrNull { it.wireName == value }
    }
}

/** Body of `clipboard.ack` (protocol §5.2). */
data class ClipboardAckBody(
    val refId: String,
    val accepted: Boolean,
    val reason: ClipboardRejectReason? = null
) {
    fun toJson(): JsonObject = JsonObject().apply {
        addProperty("ref_id", refId)
        addProperty("accepted", accepted)
        reason?.let { addProperty("reason", it.wireName) }
    }
}

sealed class ClipboardMessageException(message: String) : Exception(message) {
    data class NotAClipboardMessage(val type: MessageType) :
        ClipboardMessageException("${type.wireName} is not a clipboard message")

    data class MissingField(val name: String) : ClipboardMessageException("missing field '$name'")
    data class InvalidField(val name: String) : ClipboardMessageException("invalid field '$name'")
    data class PayloadTooLarge(val bytes: Int) :
        ClipboardMessageException("clipboard payload is $bytes bytes")
}

/** Encoding and validation for clipboard messages. Mirrors the Swift `ClipboardMessageCodec`. */
object ClipboardMessageCodec {
    /** Protocol §5.2 / §10: 256 KiB of UTF-8. */
    const val MAXIMUM_TEXT_BYTES = 262_144

    fun updateEnvelope(body: ClipboardUpdateBody, nowMillis: Long = System.currentTimeMillis()) = Envelope(
        v = Envelope.CURRENT_VERSION,
        id = java.util.UUID.randomUUID().toString().lowercase(),
        type = requireNotNull(MessageType.CLIPBOARD_UPDATE.wireName),
        ts = nowMillis,
        body = body.toJson()
    )

    fun ackEnvelope(body: ClipboardAckBody, nowMillis: Long = System.currentTimeMillis()) = Envelope(
        v = Envelope.CURRENT_VERSION,
        id = java.util.UUID.randomUUID().toString().lowercase(),
        type = requireNotNull(MessageType.CLIPBOARD_ACK.wireName),
        ts = nowMillis,
        body = body.toJson()
    )

    fun hashOf(text: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(text.toByteArray(Charsets.UTF_8))
            .toHexString()

    fun decodeUpdate(envelope: Envelope): ClipboardUpdateBody {
        if (envelope.messageType != MessageType.CLIPBOARD_UPDATE) {
            throw ClipboardMessageException.NotAClipboardMessage(envelope.messageType)
        }
        val body = envelope.body ?: throw ClipboardMessageException.MissingField("body")

        val contentType = ClipboardContentType.fromWire(
            body.stringOrNull("content_type")
                ?: throw ClipboardMessageException.MissingField("content_type")
        ) ?: throw ClipboardMessageException.InvalidField("content_type")

        val text = body.stringOrNull("text")
            ?: throw ClipboardMessageException.MissingField("text")

        // Check the byte cost, not the character count: the limit is about bytes on the wire.
        val byteCount = text.toByteArray(Charsets.UTF_8).size
        if (byteCount > MAXIMUM_TEXT_BYTES) {
            throw ClipboardMessageException.PayloadTooLarge(byteCount)
        }

        val hash = body.stringOrNull("hash")
            ?.takeIf { it.length == Fingerprint.HEX_LENGTH && it.all { c -> c.isHexDigit() } }
            ?: throw ClipboardMessageException.InvalidField("hash")

        val changeCount = body.intOrNull("change_count")
            ?.takeIf { it >= 0 }
            ?: throw ClipboardMessageException.InvalidField("change_count")

        val originId = DeviceId.parse(
            body.stringOrNull("origin_id") ?: ""
        ) ?: throw ClipboardMessageException.InvalidField("origin_id")

        val sensitive = body.get("sensitive")
            ?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isBoolean }
            ?.asBoolean
            ?: false

        return ClipboardUpdateBody(
            contentType = contentType,
            text = text,
            hash = hash.lowercase(),
            changeCount = changeCount,
            originId = originId,
            sensitive = sensitive
        )
    }

    fun decodeAck(envelope: Envelope): ClipboardAckBody {
        if (envelope.messageType != MessageType.CLIPBOARD_ACK) {
            throw ClipboardMessageException.NotAClipboardMessage(envelope.messageType)
        }
        val body = envelope.body ?: throw ClipboardMessageException.MissingField("body")

        val refId = body.stringOrNull("ref_id")
            ?: throw ClipboardMessageException.MissingField("ref_id")
        val accepted = body.get("accepted")
            ?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isBoolean }
            ?.asBoolean
            ?: throw ClipboardMessageException.MissingField("accepted")
        val reason = body.stringOrNull("reason")?.let { ClipboardRejectReason.fromWire(it) }

        return ClipboardAckBody(refId = refId, accepted = accepted, reason = reason)
    }
}
