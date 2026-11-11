package id.my.wandidev.klyndro.protocol

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.util.UUID

/**
 * Body of a `notification.post` envelope (protocol §5.3).
 */
data class NotificationPostBody(
    val key: String,
    val packageName: String,
    val appName: String,
    val title: String,
    val text: String,
    val postedAt: Long,
    val sensitive: Boolean = false
) {
    fun toJson(): JsonObject = JsonObject().apply {
        addProperty("key", key)
        addProperty("package", packageName)
        addProperty("app_name", appName)
        addProperty("title", title)
        addProperty("text", text)
        addProperty("posted_at", postedAt)
        addProperty("sensitive", sensitive)
    }

    companion object {
        fun fromJson(json: JsonObject): NotificationPostBody {
            return NotificationPostBody(
                key = json.get("key")?.asString
                    ?: throw NotificationMessageException.MissingField("key"),
                packageName = json.get("package")?.asString
                    ?: throw NotificationMessageException.MissingField("package"),
                appName = json.get("app_name")?.asString
                    ?: throw NotificationMessageException.MissingField("app_name"),
                title = json.get("title")?.asString ?: "",
                text = json.get("text")?.asString ?: "",
                postedAt = json.get("posted_at")?.asLong ?: System.currentTimeMillis(),
                sensitive = json.get("sensitive")?.asBoolean ?: false
            )
        }
    }
}

sealed class NotificationMessageException(message: String) : Exception(message) {
    data class NotANotificationMessage(val type: MessageType) :
        NotificationMessageException("${type.wireName} is not a notification message")

    data class MissingField(val name: String) : NotificationMessageException("missing field '$name'")
    data class PayloadTooLarge(val bytes: Int, val limit: Int) :
        NotificationMessageException("payload field is $bytes bytes (limit $limit)")
}

/**
 * Enforces size limits and wire encoding for `notification.post`.
 */
object NotificationMessageCodec {
    const val MAX_TITLE_BYTES = 1024
    const val MAX_TEXT_BYTES = 8192
    const val MAX_PACKAGE_BYTES = 256

    fun postEnvelope(body: NotificationPostBody): Envelope {
        val titleBytes = body.title.toByteArray(Charsets.UTF_8).size
        if (titleBytes > MAX_TITLE_BYTES) {
            throw NotificationMessageException.PayloadTooLarge(titleBytes, MAX_TITLE_BYTES)
        }
        val textBytes = body.text.toByteArray(Charsets.UTF_8).size
        if (textBytes > MAX_TEXT_BYTES) {
            throw NotificationMessageException.PayloadTooLarge(textBytes, MAX_TEXT_BYTES)
        }
        val packageBytes = body.packageName.toByteArray(Charsets.UTF_8).size
        if (packageBytes > MAX_PACKAGE_BYTES) {
            throw NotificationMessageException.PayloadTooLarge(packageBytes, MAX_PACKAGE_BYTES)
        }

        return Envelope(
            v = Envelope.CURRENT_VERSION,
            id = UUID.randomUUID().toString().lowercase(),
            type = MessageType.NOTIFICATION_POST.wireName!!,
            ts = System.currentTimeMillis(),
            body = body.toJson()
        )
    }

    fun decodePost(envelope: Envelope): NotificationPostBody {
        if (envelope.messageType != MessageType.NOTIFICATION_POST) {
            throw NotificationMessageException.NotANotificationMessage(envelope.messageType)
        }
        val body = envelope.body ?: throw NotificationMessageException.MissingField("body")
        return NotificationPostBody.fromJson(body)
    }
}
