package id.my.wandidev.klyndro.protocol

import com.google.gson.JsonObject
import java.io.File
import java.util.UUID

data class FileOfferBody(
    val transferId: String,
    val filename: String,
    val sizeBytes: Long,
    val sha256: String,
    val mimeType: String = "application/octet-stream"
) {
    fun toJson(): JsonObject = JsonObject().apply {
        addProperty("transfer_id", transferId)
        addProperty("filename", FileMessageCodec.sanitizeFilename(filename))
        addProperty("size_bytes", sizeBytes)
        addProperty("sha256", sha256.lowercase())
        addProperty("mime_type", mimeType)
    }

    companion object {
        fun fromJson(json: JsonObject): FileOfferBody = FileOfferBody(
            transferId = json.get("transfer_id")?.asString ?: throw FileMessageException.MissingField("transfer_id"),
            filename = json.get("filename")?.asString ?: throw FileMessageException.MissingField("filename"),
            sizeBytes = json.get("size_bytes")?.asLong ?: throw FileMessageException.MissingField("size_bytes"),
            sha256 = json.get("sha256")?.asString?.lowercase() ?: throw FileMessageException.MissingField("sha256"),
            mimeType = json.get("mime_type")?.asString ?: "application/octet-stream"
        )
    }
}

data class FileAcceptBody(val transferId: String) {
    fun toJson(): JsonObject = JsonObject().apply { addProperty("transfer_id", transferId) }
    companion object {
        fun fromJson(json: JsonObject): FileAcceptBody =
            FileAcceptBody(json.get("transfer_id")?.asString ?: throw FileMessageException.MissingField("transfer_id"))
    }
}

data class FileRejectBody(val transferId: String, val reason: String) {
    fun toJson(): JsonObject = JsonObject().apply {
        addProperty("transfer_id", transferId)
        addProperty("reason", reason)
    }
    companion object {
        fun fromJson(json: JsonObject): FileRejectBody = FileRejectBody(
            transferId = json.get("transfer_id")?.asString ?: throw FileMessageException.MissingField("transfer_id"),
            reason = json.get("reason")?.asString ?: "rejected"
        )
    }
}

data class FileChunkBody(val transferId: String, val offset: Long, val dataB64: String) {
    fun toJson(): JsonObject = JsonObject().apply {
        addProperty("transfer_id", transferId)
        addProperty("offset", offset)
        addProperty("data_b64", dataB64)
    }
    companion object {
        fun fromJson(json: JsonObject): FileChunkBody = FileChunkBody(
            transferId = json.get("transfer_id")?.asString ?: throw FileMessageException.MissingField("transfer_id"),
            offset = json.get("offset")?.asLong ?: throw FileMessageException.MissingField("offset"),
            dataB64 = json.get("data_b64")?.asString ?: throw FileMessageException.MissingField("data_b64")
        )
    }
}

data class FileCompleteBody(val transferId: String, val sha256: String) {
    fun toJson(): JsonObject = JsonObject().apply {
        addProperty("transfer_id", transferId)
        addProperty("sha256", sha256.lowercase())
    }
    companion object {
        fun fromJson(json: JsonObject): FileCompleteBody = FileCompleteBody(
            transferId = json.get("transfer_id")?.asString ?: throw FileMessageException.MissingField("transfer_id"),
            sha256 = json.get("sha256")?.asString?.lowercase() ?: throw FileMessageException.MissingField("sha256")
        )
    }
}

sealed class FileMessageException(message: String) : Exception(message) {
    data class NotAFileMessage(val type: MessageType) : FileMessageException("${type.wireName} is not a file message")
    data class MissingField(val name: String) : FileMessageException("missing field '$name'")
}

object FileMessageCodec {
    const val MAX_CHUNK_RAW_BYTES = 512 * 1024

    fun offerEnvelope(body: FileOfferBody): Envelope = Envelope(
        v = Envelope.CURRENT_VERSION,
        id = UUID.randomUUID().toString().lowercase(),
        type = MessageType.FILE_OFFER.wireName!!,
        ts = System.currentTimeMillis(),
        body = body.toJson()
    )

    fun decodeOffer(envelope: Envelope): FileOfferBody {
        if (envelope.messageType != MessageType.FILE_OFFER) {
            throw FileMessageException.NotAFileMessage(envelope.messageType)
        }
        val body = envelope.body ?: throw FileMessageException.MissingField("body")
        return FileOfferBody.fromJson(body)
    }

    fun sanitizeFilename(name: String): String {
        val base = File(name).name
        val clean = base.replace("/", "_").replace("\\", "_")
        return if (clean.isBlank()) "unnamed_file" else clean.take(255)
    }
}
