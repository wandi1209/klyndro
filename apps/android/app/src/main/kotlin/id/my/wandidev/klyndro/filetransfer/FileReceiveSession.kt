package id.my.wandidev.klyndro.filetransfer

import id.my.wandidev.klyndro.protocol.FileChunkBody
import id.my.wandidev.klyndro.protocol.FileCompleteBody
import id.my.wandidev.klyndro.protocol.FileMessageCodec
import id.my.wandidev.klyndro.protocol.FileOfferBody
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Base64

/**
 * Where a received file is written. The Android implementation uses MediaStore; tests use memory.
 * `commit` makes the file visible to the user, `discard` removes everything written so far.
 */
interface FileSink {
    fun open(displayName: String, mimeType: String): OutputStream?
    fun commit(): String?
    fun discard()
}

sealed class OfferDecision {
    data object Accept : OfferDecision()
    data class Reject(val reason: String) : OfferDecision()
}

sealed class ReceiveResult {
    data class Saved(val displayName: String) : ReceiveResult()
    data class Failed(val reason: String) : ReceiveResult()
}

/**
 * Receives one file at a time. Pure state machine over a [FileSink], so the checks that guard the
 * disk are unit-testable: size is capped before anything is written, chunks must arrive in order
 * and inside the declared size, and the file is kept only when the SHA-256 matches the offer.
 */
class FileReceiveSession(
    private val newSink: () -> FileSink,
    private val maxBytes: Long = MAX_FILE_BYTES
) {
    private var offer: FileOfferBody? = null
    private var sink: FileSink? = null
    private var stream: OutputStream? = null
    private var digest: MessageDigest = MessageDigest.getInstance("SHA-256")
    private var received = 0L

    val isBusy: Boolean get() = offer != null

    fun onOffer(incoming: FileOfferBody): OfferDecision {
        if (offer != null) return OfferDecision.Reject("busy")
        if (incoming.sizeBytes < 0) return OfferDecision.Reject("invalid-size")
        if (incoming.sizeBytes > maxBytes) return OfferDecision.Reject("too-large")
        if (!SHA256_HEX.matches(incoming.sha256)) return OfferDecision.Reject("invalid-hash")

        val name = FileMessageCodec.sanitizeFilename(incoming.filename)
        val newSink = newSink()
        val out = newSink.open(name, incoming.mimeType) ?: return OfferDecision.Reject("storage-unavailable")

        offer = incoming.copy(filename = name)
        sink = newSink
        stream = out
        digest = MessageDigest.getInstance("SHA-256")
        received = 0L
        return OfferDecision.Accept
    }

    /** Returns false (and abandons the transfer) when the chunk is not acceptable. */
    fun onChunk(chunk: FileChunkBody): Boolean {
        val current = offer ?: return false
        if (chunk.transferId != current.transferId) return false
        // In-order only: the sender streams sequentially, so a gap or overlap means corruption.
        if (chunk.offset != received) return fail()

        val data = try {
            Base64.getDecoder().decode(chunk.dataB64)
        } catch (_: IllegalArgumentException) {
            return fail()
        }
        if (data.size > FileMessageCodec.MAX_CHUNK_RAW_BYTES) return fail()
        if (received + data.size > current.sizeBytes) return fail()

        return try {
            stream?.write(data)
            digest.update(data)
            received += data.size
            true
        } catch (_: java.io.IOException) {
            fail()
        }
    }

    fun onComplete(complete: FileCompleteBody): ReceiveResult {
        val current = offer ?: return ReceiveResult.Failed("no-transfer")
        if (complete.transferId != current.transferId) return ReceiveResult.Failed("wrong-transfer")

        if (received != current.sizeBytes) {
            abandon()
            return ReceiveResult.Failed("size-mismatch")
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (actual != current.sha256 || actual != complete.sha256) {
            abandon()
            return ReceiveResult.Failed("hash-mismatch")
        }

        try {
            stream?.close()
        } catch (_: java.io.IOException) {
            abandon()
            return ReceiveResult.Failed("write-failed")
        }
        val saved = sink?.commit()
        reset()
        return if (saved != null) ReceiveResult.Saved(saved) else ReceiveResult.Failed("write-failed")
    }

    /** Drops an in-flight transfer, for example when the connection closes. */
    fun abort() = abandon()

    private fun fail(): Boolean {
        abandon()
        return false
    }

    private fun abandon() {
        try {
            stream?.close()
        } catch (_: java.io.IOException) {
            // Already failing; nothing further to report.
        }
        sink?.discard()
        reset()
    }

    private fun reset() {
        offer = null
        sink = null
        stream = null
        received = 0L
    }

    companion object {
        /** A phone should not be filled by a peer that lies about, or never finishes, a transfer. */
        const val MAX_FILE_BYTES = 2L * 1024 * 1024 * 1024
        private val SHA256_HEX = Regex("^[0-9a-f]{64}$")
    }
}
