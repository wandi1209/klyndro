package id.my.wandidev.klyndro.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class FrameCodecTest {

    private val sample = Frame(
        FrameKind.ENVELOPE,
        """{"v":1,"id":"3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22","type":"ping","ts":1}"""
            .toByteArray(Charsets.UTF_8)
    )

    @Test
    fun `round trips a single frame`() {
        val encoded = FrameEncoder.encode(sample)
        val decoder = FrameDecoder()
        decoder.append(encoded)

        val decoded = decoder.nextFrame()
        assertEquals(sample, decoded)
        assertEquals(0, decoder.bufferedByteCount)
        assertNull(decoder.nextFrame())
    }

    @Test
    fun `length prefix is big endian and includes the kind byte`() {
        val encoder = FrameEncoder
        val encoded = encoder.encode(sample)
        val declared = ((encoded[0].toLong() and 0xFF) shl 24) or
            ((encoded[1].toLong() and 0xFF) shl 16) or
            ((encoded[2].toLong() and 0xFF) shl 8) or
            (encoded[3].toLong() and 0xFF)

        assertEquals((sample.payload.size + 1).toLong(), declared)
        assertEquals(FrameKind.ENVELOPE.wireByte.toByte(), encoded[4])
    }

    @Test
    fun `reassembles a frame delivered one byte at a time`() {
        val encoded = FrameEncoder.encode(sample)
        val decoder = FrameDecoder()

        encoded.dropLast(1).forEach { byte ->
            decoder.append(byteArrayOf(byte))
            assertNull(decoder.nextFrame())
        }
        decoder.append(byteArrayOf(encoded.last()))
        assertEquals(sample, decoder.nextFrame())
    }

    @Test
    fun `decodes several frames from one buffer`() {
        val other = Frame(FrameKind.ENVELOPE, "{}".toByteArray(Charsets.UTF_8))
        val decoder = FrameDecoder()
        decoder.append(FrameEncoder.encode(sample) + FrameEncoder.encode(other))

        assertEquals(sample, decoder.nextFrame())
        assertEquals(other, decoder.nextFrame())
        assertNull(decoder.nextFrame())
    }

    @Test
    fun `rejects a length above the wire limit`() {
        val oversized = FramingLimits.MAX_FRAME_BYTES + 1
        val decoder = FrameDecoder()
        decoder.append(
            byteArrayOf(
                ((oversized ushr 24) and 0xFF).toByte(),
                ((oversized ushr 16) and 0xFF).toByte(),
                ((oversized ushr 8) and 0xFF).toByte(),
                (oversized and 0xFF).toByte(),
                FrameKind.ENVELOPE.wireByte.toByte()
            )
        )

        assertThrows(ProtocolException.FrameTooLarge::class.java) { decoder.nextFrame() }
    }

    @Test
    fun `rejects a length with the high bit set instead of wrapping`() {
        val decoder = FrameDecoder()
        // 0xFFFFFFFF: as a signed Int this would be -1 and look like an empty frame.
        decoder.append(
            byteArrayOf(
                0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
                FrameKind.ENVELOPE.wireByte.toByte()
            )
        )

        val error = assertThrows(ProtocolException.FrameTooLarge::class.java) { decoder.nextFrame() }
        assertEquals(4_294_967_295L, error.bytes)
    }

    @Test
    fun `rejects a zero length`() {
        val decoder = FrameDecoder()
        decoder.append(byteArrayOf(0, 0, 0, 0))
        assertThrows(ProtocolException.EmptyFrame::class.java) { decoder.nextFrame() }
    }

    @Test
    fun `rejects an unknown frame kind`() {
        val decoder = FrameDecoder()
        decoder.append(byteArrayOf(0, 0, 0, 2, 0x7F, 0x00))
        assertThrows(ProtocolException.UnsupportedFrameKind::class.java) { decoder.nextFrame() }
    }

    @Test
    fun `encoder refuses to produce an oversized frame`() {
        val payload = ByteArray(FramingLimits.MAX_FRAME_BYTES) { 0x41 }
        assertThrows(ProtocolException.FrameTooLarge::class.java) {
            FrameEncoder.encode(Frame(FrameKind.ENVELOPE, payload))
        }
    }

    @Test
    fun `accepts a payload exactly at the limit`() {
        val payload = ByteArray(FramingLimits.MAX_PAYLOAD_BYTES) { 0x41 }
        val encoded = FrameEncoder.encode(Frame(FrameKind.ENVELOPE, payload))
        val decoder = FrameDecoder()
        decoder.append(encoded)

        assertArrayEquals(payload, decoder.nextFrame()?.payload)
    }
}
