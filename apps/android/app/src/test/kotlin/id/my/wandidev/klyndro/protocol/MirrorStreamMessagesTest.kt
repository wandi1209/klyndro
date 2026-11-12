package id.my.wandidev.klyndro.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.nio.ByteBuffer

class MirrorStreamMessagesTest {

    @Test
    fun `round trips mirror stream start and stop`() {
        val id = "11111111-2222-4333-8444-555555555555"
        val start = MirrorStreamStartBody(id, 51234, "h264", 1080, 30, 4_000_000)
        assertEquals(start, MirrorStreamStartBody.decode(start.toEnvelope()))

        val stop = MirrorStreamStopBody(id, "user_stopped")
        assertEquals(stop, MirrorStreamStopBody.decode(stop.toEnvelope()))
    }

    @Test
    fun `rejects invalid bounds`() {
        val bad = MirrorStreamStartBody("11111111-2222-4333-8444-555555555555", 0).toEnvelope()
        assertNull(MirrorStreamStartBody.decode(bad))
    }

    @Test
    fun `encodes video packet header big-endian and scales dimensions evenly`() {
        val payload = byteArrayOf(0x00, 0x00, 0x00, 0x01, 0x65)
        val encoded = VideoStreamPacketCodec.encode(VideoStreamPacketCodec.FLAG_KEY_FRAME, 33_333L, payload)
        val buf = ByteBuffer.wrap(encoded)
        assertEquals(9 + payload.size, buf.int)
        assertEquals(VideoStreamPacketCodec.FLAG_KEY_FRAME, buf.get())
        assertEquals(33_333L, buf.long)
        val tail = ByteArray(payload.size)
        buf.get(tail)
        assertArrayEquals(payload, tail)

        assertEquals(1080 to 2400, VideoStreamPacketCodec.scaledDimensions(1080, 2400, 1080))
        assertEquals(720 to 1600, VideoStreamPacketCodec.scaledDimensions(1080, 2400, 720))
    }
}
