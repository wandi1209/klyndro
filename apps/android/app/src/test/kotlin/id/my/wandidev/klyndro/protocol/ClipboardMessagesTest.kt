package id.my.wandidev.klyndro.protocol

import com.google.gson.JsonObject
import id.my.wandidev.klyndro.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ClipboardMessagesTest {

    private val origin = DeviceId.parse("0011223344556677")!!

    private fun update(
        text: String = "hello",
        changeCount: Int = 1,
        sensitive: Boolean = false
    ) = ClipboardUpdateBody(
        contentType = ClipboardContentType.PLAIN_TEXT,
        text = text,
        hash = ClipboardMessageCodec.hashOf(text),
        changeCount = changeCount,
        originId = origin,
        sensitive = sensitive
    )

    private fun envelope(body: JsonObject) = Envelope(
        v = Envelope.CURRENT_VERSION,
        id = java.util.UUID.randomUUID().toString(),
        type = MessageType.CLIPBOARD_UPDATE.wireName!!,
        ts = 1,
        body = body
    )

    @Test
    fun `hash is sha-256 of the utf-8 text`() {
        // Known value: SHA-256("abc"), published in every cryptography primer.
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            ClipboardMessageCodec.hashOf("abc")
        )
        assertEquals(64, ClipboardMessageCodec.hashOf("").length)
    }

    @Test
    fun `hash matches the macOS implementation for the shared fixture`() {
        // The fixture was written once and is read by both suites; if the two hash implementations
        // diverged, loop suppression would silently fail across platforms.
        val fixture = com.google.gson.JsonParser.parseString(
            Fixtures.text("protocol/fixtures/clipboard-update.json")
        ).asJsonObject
        val body = fixture.getAsJsonObject("body")
        val text = body.get("text").asString
        assertEquals(body.get("hash").asString, ClipboardMessageCodec.hashOf(text))
    }

    @Test
    fun `round trips an update`() {
        val body = update(text = "klyndro", changeCount = 7, sensitive = true)
        val decoded = ClipboardMessageCodec.decodeUpdate(envelope(body.toJson()))
        assertEquals(body, decoded)
    }

    @Test
    fun `round trips an ack with and without a reason`() {
        val accepted = ClipboardAckBody(refId = "ref-1", accepted = true)
        val acceptedEnvelope = Envelope(1, "id", MessageType.CLIPBOARD_ACK.wireName!!, 1, accepted.toJson())
        assertEquals(accepted, ClipboardMessageCodec.decodeAck(acceptedEnvelope))

        val refused = ClipboardAckBody("ref-2", false, ClipboardRejectReason.TOO_LARGE)
        val refusedEnvelope = Envelope(1, "id", MessageType.CLIPBOARD_ACK.wireName!!, 1, refused.toJson())
        assertEquals(refused, ClipboardMessageCodec.decodeAck(refusedEnvelope))
    }

    @Test
    fun `rejects an unsupported content type`() {
        val body = update().toJson().apply { addProperty("content_type", "image/png") }
        assertThrows(ClipboardMessageException.InvalidField::class.java) {
            ClipboardMessageCodec.decodeUpdate(envelope(body))
        }
    }

    @Test
    fun `rejects content over 256 KiB counting bytes not characters`() {
        // 131 072 CJK characters are under the character limit but over the byte limit.
        val cjk = "東".repeat(131_072)
        val body = update(text = cjk).toJson()
        val error = assertThrows(ClipboardMessageException.PayloadTooLarge::class.java) {
            ClipboardMessageCodec.decodeUpdate(envelope(body))
        }
        assertEquals(3 * 131_072, error.bytes)
    }

    @Test
    fun `rejects a malformed hash counter or origin`() {
        assertThrows(ClipboardMessageException.InvalidField::class.java) {
            ClipboardMessageCodec.decodeUpdate(envelope(update().toJson().apply { addProperty("hash", "abc") }))
        }
        assertThrows(ClipboardMessageException.InvalidField::class.java) {
            ClipboardMessageCodec.decodeUpdate(envelope(update().toJson().apply { addProperty("change_count", -1) }))
        }
        assertThrows(ClipboardMessageException.InvalidField::class.java) {
            ClipboardMessageCodec.decodeUpdate(envelope(update().toJson().apply { addProperty("origin_id", "short") }))
        }
    }

    @Test
    fun `refuses to read a non-clipboard message`() {
        val ping = Envelope(1, "id", MessageType.PING.wireName!!, 1, null)
        assertThrows(ClipboardMessageException.NotAClipboardMessage::class.java) {
            ClipboardMessageCodec.decodeUpdate(ping)
        }
    }

    @Test
    fun `treats a missing sensitive flag as not sensitive`() {
        val body = update().toJson().apply { remove("sensitive") }
        assertEquals(false, ClipboardMessageCodec.decodeUpdate(envelope(body)).sensitive)
    }
}
