package id.my.wandidev.klyndro.filetransfer

import id.my.wandidev.klyndro.protocol.FileChunkBody
import id.my.wandidev.klyndro.protocol.FileCompleteBody
import id.my.wandidev.klyndro.protocol.FileOfferBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Base64

class FileReceiveSessionTest {

    private class MemorySink(private val openable: Boolean = true) : FileSink {
        val bytes = ByteArrayOutputStream()
        var name: String? = null
        var committed = false
        var discarded = false

        override fun open(displayName: String, mimeType: String): OutputStream? {
            if (!openable) return null
            name = displayName
            return bytes
        }

        override fun commit(): String? {
            committed = true
            return name
        }

        override fun discard() {
            discarded = true
        }
    }

    private fun sha(data: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }

    private fun offer(data: ByteArray, name: String = "photo.jpg", id: String = "t1") =
        FileOfferBody(id, name, data.size.toLong(), sha(data))

    private fun chunk(data: ByteArray, offset: Long, id: String = "t1") =
        FileChunkBody(id, offset, Base64.getEncoder().encodeToString(data))

    @Test
    fun `a complete in-order transfer with a matching hash is saved`() {
        val sink = MemorySink()
        val session = FileReceiveSession({ sink })
        val data = ByteArray(1000) { it.toByte() }

        assertEquals(OfferDecision.Accept, session.onOffer(offer(data)))
        assertTrue(session.onChunk(chunk(data.copyOfRange(0, 600), 0)))
        assertTrue(session.onChunk(chunk(data.copyOfRange(600, 1000), 600)))
        val result = session.onComplete(FileCompleteBody("t1", sha(data)))

        assertEquals(ReceiveResult.Saved("photo.jpg"), result)
        assertTrue(sink.committed)
        assertFalse(sink.discarded)
        assertTrue(data.contentEquals(sink.bytes.toByteArray()))
        assertFalse(session.isBusy)
    }

    @Test
    fun `a hash mismatch discards the file`() {
        val sink = MemorySink()
        val session = FileReceiveSession({ sink })
        val data = ByteArray(10) { 7 }
        session.onOffer(offer(data))
        session.onChunk(chunk(ByteArray(10) { 8 }, 0))

        assertEquals(ReceiveResult.Failed("hash-mismatch"), session.onComplete(FileCompleteBody("t1", sha(data))))
        assertTrue(sink.discarded)
        assertFalse(sink.committed)
    }

    @Test
    fun `fewer bytes than offered is a size mismatch`() {
        val sink = MemorySink()
        val session = FileReceiveSession({ sink })
        val data = ByteArray(10) { 1 }
        session.onOffer(offer(data))
        session.onChunk(chunk(data.copyOfRange(0, 5), 0))

        assertEquals(ReceiveResult.Failed("size-mismatch"), session.onComplete(FileCompleteBody("t1", sha(data))))
        assertTrue(sink.discarded)
    }

    @Test
    fun `an offer above the cap is rejected before anything is opened`() {
        var opened = false
        val session = FileReceiveSession({ opened = true; MemorySink() }, maxBytes = 100)
        val data = ByteArray(101)

        assertEquals(OfferDecision.Reject("too-large"), session.onOffer(offer(data)))
        assertFalse(opened)
    }

    @Test
    fun `negative size and malformed hash are rejected`() {
        val session = FileReceiveSession({ MemorySink() })
        assertEquals(
            OfferDecision.Reject("invalid-size"),
            session.onOffer(FileOfferBody("t1", "a", -1, "0".repeat(64)))
        )
        assertEquals(
            OfferDecision.Reject("invalid-hash"),
            session.onOffer(FileOfferBody("t1", "a", 1, "XYZ"))
        )
    }

    @Test
    fun `a second offer while busy is rejected`() {
        val session = FileReceiveSession({ MemorySink() })
        val data = ByteArray(4)
        assertEquals(OfferDecision.Accept, session.onOffer(offer(data, id = "t1")))
        assertEquals(OfferDecision.Reject("busy"), session.onOffer(offer(data, id = "t2")))
    }

    @Test
    fun `a chunk with a gap abandons the transfer`() {
        val sink = MemorySink()
        val session = FileReceiveSession({ sink })
        val data = ByteArray(10)
        session.onOffer(offer(data))

        assertFalse(session.onChunk(chunk(ByteArray(5), 3)))
        assertTrue(sink.discarded)
        assertFalse(session.isBusy)
    }

    @Test
    fun `data beyond the declared size abandons the transfer`() {
        val sink = MemorySink()
        val session = FileReceiveSession({ sink })
        val data = ByteArray(4)
        session.onOffer(offer(data))

        assertFalse(session.onChunk(chunk(ByteArray(5), 0)))
        assertTrue(sink.discarded)
    }

    @Test
    fun `invalid base64 abandons the transfer`() {
        val sink = MemorySink()
        val session = FileReceiveSession({ sink })
        session.onOffer(offer(ByteArray(4)))

        assertFalse(session.onChunk(FileChunkBody("t1", 0, "!!not base64!!")))
        assertTrue(sink.discarded)
    }

    @Test
    fun `a chunk for another transfer is ignored without disturbing the active one`() {
        val sink = MemorySink()
        val session = FileReceiveSession({ sink })
        val data = ByteArray(4) { 9 }
        session.onOffer(offer(data, id = "t1"))

        assertFalse(session.onChunk(chunk(data, 0, id = "other")))
        assertTrue(session.isBusy)
        assertFalse(sink.discarded)
    }

    @Test
    fun `a path traversal filename is reduced to its base name`() {
        val sink = MemorySink()
        val session = FileReceiveSession({ sink })
        val data = ByteArray(2)
        session.onOffer(offer(data, name = "../../etc/passwd"))
        assertEquals("passwd", sink.name)
    }

    @Test
    fun `a sink that cannot open rejects the offer`() {
        val session = FileReceiveSession({ MemorySink(openable = false) })
        assertEquals(OfferDecision.Reject("storage-unavailable"), session.onOffer(offer(ByteArray(1))))
        assertFalse(session.isBusy)
    }

    @Test
    fun `abort during a transfer discards the partial file`() {
        val sink = MemorySink()
        val session = FileReceiveSession({ sink })
        session.onOffer(offer(ByteArray(10)))
        session.onChunk(chunk(ByteArray(3), 0))
        session.abort()

        assertTrue(sink.discarded)
        assertFalse(session.isBusy)
    }

    @Test
    fun `complete with no active transfer fails cleanly`() {
        val session = FileReceiveSession({ MemorySink() })
        assertEquals(ReceiveResult.Failed("no-transfer"), session.onComplete(FileCompleteBody("t1", "0".repeat(64))))
        assertNull(null)
    }
}
