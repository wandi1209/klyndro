package id.my.wandidev.klyndro.clipboard

import id.my.wandidev.klyndro.protocol.ClipboardContentType
import id.my.wandidev.klyndro.protocol.ClipboardMessageCodec
import id.my.wandidev.klyndro.protocol.ClipboardUpdateBody
import id.my.wandidev.klyndro.protocol.DeviceId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardSyncEngineTest {

    private val phoneId = DeviceId.parse("bbbbbbbbbbbbbbbb")!!
    private val macId = DeviceId.parse("aaaaaaaaaaaaaaaa")!!
    private val now = 1_762_800_000_000L

    private fun snapshot(text: String, count: Int, sensitive: Boolean = false) =
        ClipboardSnapshot(text = text, sensitive = sensitive, changeCount = count)

    private fun remote(text: String, count: Int, from: DeviceId = macId, sensitive: Boolean = false) =
        ClipboardUpdateBody(
            contentType = ClipboardContentType.PLAIN_TEXT,
            text = text,
            hash = ClipboardMessageCodec.hashOf(text),
            changeCount = count,
            originId = from,
            sensitive = sensitive
        )

    private fun engine(enabled: Boolean = true, sensitive: Boolean = false) =
        ClipboardSyncEngine(phoneId, isEnabled = enabled, allowsSensitive = sensitive)

    @Test
    fun `sends new local content exactly once`() {
        val engine = engine()

        val first = engine.outbound(snapshot("hello", 1), now)
        assertTrue(first is ClipboardOutbound.Send)
        val body = (first as ClipboardOutbound.Send).body
        assertEquals("hello", body.text)
        assertEquals(phoneId, body.originId)
        assertEquals(1, body.changeCount)
        assertEquals(ClipboardMessageCodec.hashOf("hello"), body.hash)

        // Polling the same platform change again must not resend.
        assertEquals(
            ClipboardOutbound.Suppress(ClipboardSuppressionReason.DUPLICATE),
            engine.outbound(snapshot("hello", 1), now)
        )
    }

    @Test
    fun `increments the change counter per send`() {
        val engine = engine()
        engine.outbound(snapshot("one", 1), now)
        engine.outbound(snapshot("two", 2), now)
        assertEquals(2, engine.currentChangeCounter)
    }

    @Test
    fun `suppresses everything while disabled`() {
        val engine = engine(enabled = false)
        assertEquals(
            ClipboardOutbound.Suppress(ClipboardSuppressionReason.DISABLED),
            engine.outbound(snapshot("hello", 1), now)
        )
        assertEquals(
            ClipboardInbound.Ignore(ClipboardIgnoreReason.DISABLED),
            engine.inbound(remote("hello", 1), now)
        )
    }

    @Test
    fun `does not send sensitive content unless allowed`() {
        assertEquals(
            ClipboardOutbound.Suppress(ClipboardSuppressionReason.SENSITIVE),
            engine().outbound(snapshot("secret", 1, sensitive = true), now)
        )

        val permissive = engine(sensitive = true)
        val outbound = permissive.outbound(snapshot("secret", 1, sensitive = true), now)
        assertTrue(outbound is ClipboardOutbound.Send)
        assertTrue((outbound as ClipboardOutbound.Send).body.sensitive)
    }

    @Test
    fun `does not apply sensitive content unless allowed`() {
        assertEquals(
            ClipboardInbound.Ignore(ClipboardIgnoreReason.SENSITIVE),
            engine().inbound(remote("secret", 1, sensitive = true), now)
        )
        assertEquals(
            ClipboardInbound.Apply("secret"),
            engine(sensitive = true).inbound(remote("secret", 1, sensitive = true), now)
        )
    }

    @Test
    fun `refuses to send content over the size limit`() {
        val big = "a".repeat(ClipboardMessageCodec.MAXIMUM_TEXT_BYTES + 1)
        assertEquals(
            ClipboardOutbound.Suppress(ClipboardSuppressionReason.TOO_LARGE),
            engine().outbound(snapshot(big, 1), now)
        )
    }

    @Test
    fun `ignores its own content coming back`() {
        assertEquals(
            ClipboardInbound.Ignore(ClipboardIgnoreReason.OWN_ORIGIN),
            engine().inbound(remote("mine", 1, from = phoneId), now)
        )
    }

    @Test
    fun `applies remote content once`() {
        val engine = engine()
        assertEquals(ClipboardInbound.Apply("from mac"), engine.inbound(remote("from mac", 1), now))
        assertEquals(
            ClipboardInbound.Ignore(ClipboardIgnoreReason.STALE),
            engine.inbound(remote("from mac", 1), now)
        )
    }

    @Test
    fun `the classic loop terminates`() {
        val engine = engine()

        val inbound = remote("ping-pong", 1)
        assertEquals(ClipboardInbound.Apply("ping-pong"), engine.inbound(inbound, now))
        engine.noteApplied(inbound, now)

        // The clipboard listener fires for our own write; it must not be sent back.
        assertEquals(
            ClipboardOutbound.Suppress(ClipboardSuppressionReason.ECHO_OF_REMOTE),
            engine.outbound(snapshot("ping-pong", 42), now + 400)
        )

        // Even after the window, the same text is not re-sent.
        assertEquals(
            ClipboardOutbound.Suppress(ClipboardSuppressionReason.DUPLICATE),
            engine.outbound(snapshot("ping-pong", 43), now + 60_000)
        )

        // Genuinely new content still goes out.
        val next = engine.outbound(snapshot("something else", 44), now + 61_000)
        assertTrue(next is ClipboardOutbound.Send)
    }

    @Test
    fun `a stale update from before a reconnect is ignored`() {
        val engine = engine()
        assertEquals(ClipboardInbound.Apply("newer"), engine.inbound(remote("newer", 5), now))
        assertEquals(
            ClipboardInbound.Ignore(ClipboardIgnoreReason.STALE),
            engine.inbound(remote("older", 3), now)
        )
    }

    @Test
    fun `a reconnect does not re-send unchanged content`() {
        val engine = engine()
        engine.outbound(snapshot("mine", 1), now)
        engine.resetSessionState()
        assertEquals(
            ClipboardOutbound.Suppress(ClipboardSuppressionReason.DUPLICATE),
            engine.outbound(snapshot("mine", 1), now)
        )
    }

    @Test
    fun `a reconnect clears per-origin staleness`() {
        val engine = engine()
        assertEquals(ClipboardInbound.Apply("theirs"), engine.inbound(remote("theirs", 5), now))
        assertEquals(
            ClipboardInbound.Ignore(ClipboardIgnoreReason.STALE),
            engine.inbound(remote("older", 3), now)
        )

        engine.resetSessionState()

        // The peer restarts its counter after reconnecting, so a lower value is legitimate again.
        assertEquals(ClipboardInbound.Apply("older"), engine.inbound(remote("older", 3), now))
    }

    @Test
    fun `re-copying older text after other content is a genuine new copy`() {
        val engine = engine()
        engine.outbound(snapshot("first", 1), now)
        engine.outbound(snapshot("second", 2), now)

        val recopy = engine.outbound(snapshot("first", 3), now)
        assertTrue("re-copying older text must be sent", recopy is ClipboardOutbound.Send)
    }

    @Test
    fun `empty clipboards are ignored but whitespace is not`() {
        val engine = engine()
        assertEquals(
            ClipboardOutbound.Suppress(ClipboardSuppressionReason.EMPTY),
            engine.outbound(snapshot("", 1), now)
        )
        assertTrue(engine.outbound(snapshot(" ", 2), now) is ClipboardOutbound.Send)
    }
}
