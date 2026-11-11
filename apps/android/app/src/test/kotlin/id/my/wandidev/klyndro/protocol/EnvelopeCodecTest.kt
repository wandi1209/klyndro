package id.my.wandidev.klyndro.protocol

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class EnvelopeCodecTest {

    private fun payload(json: String) = json.toByteArray(Charsets.UTF_8)

    @Test
    fun `encodes the v1 header and omits an absent body`() {
        val envelope = Envelope(
            v = 1,
            id = "3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22",
            type = "ping",
            ts = 1_762_800_000_000,
            body = null
        )

        val root = JsonParser.parseString(
            EnvelopeCodec.encode(envelope).toString(Charsets.UTF_8)
        ).asJsonObject

        assertEquals(1, root.get("v").asInt)
        assertEquals("ping", root.get("type").asString)
        assertEquals("3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22", root.get("id").asString)
        assertEquals(1_762_800_000_000L, root.get("ts").asLong)
        assertFalse("an absent body must be omitted", root.has("body"))
    }

    @Test
    fun `round trips a body`() {
        val body = JsonObject().apply {
            addProperty("text", "hello")
            addProperty("count", 3)
            addProperty("ok", true)
        }
        val envelope = Envelope(1, "3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22", "clipboard.update", 5, body)

        val decoded = EnvelopeCodec.decode(EnvelopeCodec.encode(envelope))

        assertEquals("clipboard.update", decoded.type)
        assertEquals(MessageType.CLIPBOARD_UPDATE, decoded.messageType)
        assertEquals(body.toString(), decoded.body.toString())
    }

    @Test
    fun `rejects a missing type`() {
        assertThrows(ProtocolException.MalformedEnvelope::class.java) {
            EnvelopeCodec.decode(payload("""{"v":1,"id":"3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22","ts":1}"""))
        }
    }

    @Test
    fun `rejects a missing id`() {
        assertThrows(ProtocolException.MalformedEnvelope::class.java) {
            EnvelopeCodec.decode(payload("""{"v":1,"type":"ping","ts":1}"""))
        }
    }

    @Test
    fun `rejects an id that is not a UUID`() {
        val error = assertThrows(ProtocolException.MalformedEnvelope::class.java) {
            EnvelopeCodec.decode(payload("""{"v":1,"id":"42","type":"ping","ts":1}"""))
        }
        assertEquals("invalid field 'id'", error.reason)
    }

    @Test
    fun `rejects a non-integer timestamp`() {
        assertThrows(ProtocolException.MalformedEnvelope::class.java) {
            EnvelopeCodec.decode(
                payload("""{"v":1,"id":"3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22","type":"ping","ts":"soon"}""")
            )
        }
        assertThrows(ProtocolException.MalformedEnvelope::class.java) {
            EnvelopeCodec.decode(
                payload("""{"v":1,"id":"3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22","type":"ping","ts":1.5}""")
            )
        }
    }

    @Test
    fun `rejects an unsupported envelope version`() {
        val error = assertThrows(ProtocolException.UnsupportedVersion::class.java) {
            EnvelopeCodec.decode(
                payload("""{"v":2,"id":"3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22","type":"ping","ts":1}""")
            )
        }
        assertEquals(2, error.version)
    }

    @Test
    fun `rejects non-object json and invalid utf-8`() {
        assertThrows(ProtocolException.MalformedEnvelope::class.java) {
            EnvelopeCodec.decode(payload("[1,2,3]"))
        }
        assertThrows(ProtocolException.MalformedEnvelope::class.java) {
            EnvelopeCodec.decode(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x00))
        }
    }

    @Test
    fun `classifies unknown types without failing`() {
        val decoded = EnvelopeCodec.decode(
            payload("""{"v":1,"id":"3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22","type":"future.thing","ts":1}""")
        )
        assertEquals(MessageType.UNKNOWN, decoded.messageType)
        assertFalse(decoded.messageType.isKnown)
    }

    @Test
    fun `round trips through the frame layer`() {
        val envelope = Envelope(
            1,
            "3f2a9c1e-7b4d-4a11-9e3c-5d6f8a0b1c22",
            "hello",
            7,
            JsonObject().apply { addProperty("device_name", "Test") }
        )

        val frame = EnvelopeCodec.frameFor(envelope)
        assertEquals(FrameKind.ENVELOPE, frame.kind)

        val decoded = EnvelopeCodec.decode(frame)
        assertEquals(envelope.type, decoded.type)
        assertEquals(envelope.id, decoded.id)
        assertEquals(envelope.ts, decoded.ts)
        assertEquals(envelope.body.toString(), decoded.body.toString())
    }

    @Test
    fun `rejects a payload above the envelope limit`() {
        val oversized = ByteArray(FramingLimits.MAX_ENVELOPE_BYTES + 1) { 0x20 }
        assertThrows(ProtocolException.FrameTooLarge::class.java) {
            EnvelopeCodec.decode(oversized)
        }
    }

    @Test
    fun `create produces a valid envelope`() {
        val envelope = Envelope.create(MessageType.PING, now = 1_762_800_000_000)
        assertEquals(Envelope.CURRENT_VERSION, envelope.v)
        assertEquals("ping", envelope.type)
        assertNull(envelope.body)

        val decoded = EnvelopeCodec.decode(EnvelopeCodec.encode(envelope))
        assertEquals(envelope.id, decoded.id)
        assertTrue(decoded.messageType.isKnown)
    }
}
