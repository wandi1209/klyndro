package id.my.wandidev.klyndro.protocol

import com.google.gson.JsonObject
import java.nio.ByteBuffer
import java.util.UUID

data class MirrorStreamStartBody(
    val streamId: String,
    val port: Int,
    val codec: String = SUPPORTED_CODEC,
    val maxWidth: Int = 1080,
    val fps: Int = 30,
    val bitrate: Int = 4_000_000,
    val audio: Boolean = false
) {
    fun toEnvelope(): Envelope = Envelope.create(
        MessageType.MIRROR_STREAM_START,
        JsonObject().apply {
            addProperty("stream_id", streamId.lowercase())
            addProperty("port", port)
            addProperty("codec", codec)
            addProperty("max_width", maxWidth)
            addProperty("fps", fps)
            addProperty("bitrate", bitrate)
            addProperty("audio", audio)
        }
    )

    companion object {
        const val SUPPORTED_CODEC = "h264"
        private val WIDTH_RANGE = 240..2160
        private val FPS_RANGE = 1..60
        private val BITRATE_RANGE = 100_000..20_000_000

        fun decode(envelope: Envelope): MirrorStreamStartBody? {
            if (envelope.messageType != MessageType.MIRROR_STREAM_START) return null
            val body = envelope.body ?: return null
            val streamId = body.get("stream_id")?.takeIf { it.isJsonPrimitive }?.asString ?: return null
            if (runCatching { UUID.fromString(streamId) }.isFailure) return null
            val port = body.get("port")?.takeIf { it.isJsonPrimitive }?.asInt ?: return null
            if (port !in 1..65535) return null
            val codec = body.get("codec")?.takeIf { it.isJsonPrimitive }?.asString ?: return null
            if (codec != SUPPORTED_CODEC) return null
            val maxWidth = body.get("max_width")?.takeIf { it.isJsonPrimitive }?.asInt ?: return null
            if (maxWidth !in WIDTH_RANGE) return null
            val fps = body.get("fps")?.takeIf { it.isJsonPrimitive }?.asInt ?: return null
            if (fps !in FPS_RANGE) return null
            val bitrate = body.get("bitrate")?.takeIf { it.isJsonPrimitive }?.asInt ?: return null
            if (bitrate !in BITRATE_RANGE) return null
            val audio = body.get("audio")?.takeIf { it.isJsonPrimitive }?.asBoolean ?: false

            return MirrorStreamStartBody(
                streamId = streamId.lowercase(),
                port = port,
                codec = codec,
                maxWidth = maxWidth,
                fps = fps,
                bitrate = bitrate,
                audio = audio
            )
        }
    }
}

data class MirrorStreamStopBody(
    val streamId: String,
    val reason: String? = null
) {
    fun toEnvelope(): Envelope = Envelope.create(
        MessageType.MIRROR_STREAM_STOP,
        JsonObject().apply {
            addProperty("stream_id", streamId.lowercase())
            if (!reason.isNullOrEmpty()) addProperty("reason", reason)
        }
    )

    companion object {
        fun decode(envelope: Envelope): MirrorStreamStopBody? {
            if (envelope.messageType != MessageType.MIRROR_STREAM_STOP) return null
            val body = envelope.body ?: return null
            val streamId = body.get("stream_id")?.takeIf { it.isJsonPrimitive }?.asString ?: return null
            if (runCatching { UUID.fromString(streamId) }.isFailure) return null
            val reason = body.get("reason")?.takeIf { it.isJsonPrimitive }?.asString
            return MirrorStreamStopBody(streamId = streamId.lowercase(), reason = reason)
        }
    }
}

/**
 * Encodes video stream packets sent over the dedicated TLS 1.3 media socket (§5.6).
 * Format: `uint32_be length | uint8 flags | int64_be pts_us | byte[] payload`.
 */
object VideoStreamPacketCodec {
    const val FLAG_CONFIG: Byte = 0x01
    const val FLAG_KEY_FRAME: Byte = 0x02
    const val FLAG_AUDIO_PCM: Byte = 0x04
    const val MAX_PACKET_LENGTH = 4_194_304

    fun encode(flags: Byte, ptsUs: Long, payload: ByteArray): ByteArray {
        val totalLength = 9 + payload.size
        require(totalLength <= MAX_PACKET_LENGTH) { "video packet too large: $totalLength" }
        val buffer = ByteBuffer.allocate(4 + totalLength)
        buffer.putInt(totalLength)
        buffer.put(flags)
        buffer.putLong(ptsUs)
        buffer.put(payload)
        return buffer.array()
    }

    /** Computes an even scaled size preserving aspect ratio, capped at [maxWidth]. */
    fun scaledDimensions(sourceWidth: Int, sourceHeight: Int, maxWidth: Int): Pair<Int, Int> {
        require(sourceWidth > 0 && sourceHeight > 0 && maxWidth >= 2)
        val scale = if (sourceWidth > maxWidth) maxWidth.toDouble() / sourceWidth.toDouble() else 1.0
        val w = maxOf(2, ((sourceWidth * scale).toInt() / 2) * 2)
        val h = maxOf(2, ((sourceHeight * scale).toInt() / 2) * 2)
        return w to h
    }
}
