package id.my.wandidev.klyndro.protocol

/**
 * Wire limits from Klyndro Protocol v1 §10. Checked before any allocation or decoding.
 */
object FramingLimits {
    /** Maximum value of the 4-byte length field, which includes the kind byte. */
    const val MAX_FRAME_BYTES = 1_048_576

    /** Maximum JSON payload of a single envelope. */
    const val MAX_ENVELOPE_BYTES = 1_048_576

    /** Length prefix (4 bytes) + kind byte (1 byte). */
    const val HEADER_BYTES = 5

    /** Maximum number of bytes that may follow the kind byte. */
    const val MAX_PAYLOAD_BYTES = MAX_FRAME_BYTES - 1
}

/**
 * Frame kind byte, Klyndro Protocol v1 §3.
 *
 * `0x02` is reserved for file chunks from M5 and is intentionally not modelled yet.
 */
enum class FrameKind(val wireByte: Int) {
    ENVELOPE(0x01);

    companion object {
        fun fromByte(value: Int): FrameKind? = entries.firstOrNull { it.wireByte == value }
    }
}

data class Frame(val kind: FrameKind, val payload: ByteArray) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Frame) return false
        return kind == other.kind && payload.contentEquals(other.payload)
    }

    override fun hashCode(): Int = 31 * kind.hashCode() + payload.contentHashCode()
}

object FrameEncoder {
    fun encode(frame: Frame): ByteArray {
        val length = frame.payload.size + 1
        if (length > FramingLimits.MAX_FRAME_BYTES) {
            throw ProtocolException.FrameTooLarge(length.toLong())
        }

        val out = ByteArray(4 + length)
        out[0] = ((length ushr 24) and 0xFF).toByte()
        out[1] = ((length ushr 16) and 0xFF).toByte()
        out[2] = ((length ushr 8) and 0xFF).toByte()
        out[3] = (length and 0xFF).toByte()
        out[4] = frame.kind.wireByte.toByte()
        frame.payload.copyInto(out, destinationOffset = 5)
        return out
    }
}

/**
 * Streaming frame decoder, Klyndro Protocol v1 §3.
 *
 * Reads arrive as an arbitrary byte stream, so a partial frame is not an error. Any
 * exception thrown here is fatal for the connection: an unreadable length or kind means
 * the stream cannot be resynchronised.
 */
class FrameDecoder {
    private var buffer = ByteArray(0)

    val bufferedByteCount: Int get() = buffer.size

    fun append(data: ByteArray) {
        if (buffer.isEmpty()) {
            buffer = data.copyOf()
            return
        }
        val merged = ByteArray(buffer.size + data.size)
        buffer.copyInto(merged)
        data.copyInto(merged, destinationOffset = buffer.size)
        buffer = merged
    }

    fun nextFrame(): Frame? {
        if (buffer.size < 4) return null

        // Read the prefix as a Long so a length with the high bit set is reported as
        // too large rather than wrapping into a negative Int.
        val length = ((buffer[0].toLong() and 0xFF) shl 24) or
            ((buffer[1].toLong() and 0xFF) shl 16) or
            ((buffer[2].toLong() and 0xFF) shl 8) or
            (buffer[3].toLong() and 0xFF)

        if (length < 1) throw ProtocolException.EmptyFrame
        if (length > FramingLimits.MAX_FRAME_BYTES) throw ProtocolException.FrameTooLarge(length)
        if (buffer.size < 4 + length) return null

        val rawKind = buffer[4].toInt() and 0xFF
        val kind = FrameKind.fromByte(rawKind)
            ?: throw ProtocolException.UnsupportedFrameKind(rawKind)

        val end = 4 + length.toInt()
        val payload = buffer.copyOfRange(5, end)
        buffer = buffer.copyOfRange(end, buffer.size)
        return Frame(kind, payload)
    }
}
