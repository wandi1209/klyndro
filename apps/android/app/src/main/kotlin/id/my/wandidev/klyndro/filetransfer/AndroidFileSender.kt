package id.my.wandidev.klyndro.filetransfer

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Base64
import id.my.wandidev.klyndro.connection.ConnectionRuntime
import id.my.wandidev.klyndro.protocol.Envelope
import id.my.wandidev.klyndro.protocol.FileChunkBody
import id.my.wandidev.klyndro.protocol.FileCompleteBody
import id.my.wandidev.klyndro.protocol.FileMessageCodec
import id.my.wandidev.klyndro.protocol.FileOfferBody
import id.my.wandidev.klyndro.protocol.MessageType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.security.MessageDigest
import java.util.UUID

/**
 * Streams a local Android content URI to the connected Mac peer over the active session.
 */
object AndroidFileSender {

    suspend fun sendUri(context: Context, uri: Uri): Result<String> = withContext(Dispatchers.IO) {
        runCatching {
            val resolver = context.contentResolver
            val (filename, sizeBytes) = queryMetadata(context, uri)
            val mimeType = resolver.getType(uri) ?: "application/octet-stream"

            // Pass 1: compute SHA-256
            val digest = MessageDigest.getInstance("SHA-256")
            resolver.openInputStream(uri)?.use { stream ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = stream.read(buf)
                    if (n < 0) break
                    digest.update(buf, 0, n)
                }
            } ?: throw IllegalStateException("Cannot open input stream for file")

            val sha256 = digest.digest().joinToString("") { "%02x".format(it) }
            val transferId = UUID.randomUUID().toString().lowercase()

            // Send offer
            val offer = FileOfferBody(
                transferId = transferId,
                filename = filename,
                sizeBytes = sizeBytes,
                sha256 = sha256,
                mimeType = mimeType
            )
            if (!ConnectionRuntime.send(FileMessageCodec.offerEnvelope(offer))) {
                throw IllegalStateException("Not connected to Mac")
            }

            // Pass 2: stream chunks
            resolver.openInputStream(uri)?.use { stream ->
                val chunkBuf = ByteArray(FileMessageCodec.MAX_CHUNK_RAW_BYTES)
                var offset = 0L
                while (true) {
                    val read = stream.read(chunkBuf)
                    if (read < 0) break
                    val slice = if (read == chunkBuf.size) chunkBuf else chunkBuf.copyOf(read)
                    val b64 = Base64.encodeToString(slice, Base64.NO_WRAP)
                    val chunk = FileChunkBody(transferId, offset, b64)
                    val env = Envelope.create(MessageType.FILE_CHUNK, chunk.toJson())
                    if (!ConnectionRuntime.send(env)) {
                        throw IllegalStateException("Transfer aborted mid-stream")
                    }
                    offset += read
                }
            }

            // Send complete
            val complete = FileCompleteBody(transferId, sha256)
            if (!ConnectionRuntime.send(Envelope.create(MessageType.FILE_COMPLETE, complete.toJson()))) {
                throw IllegalStateException("Failed to send completion signal")
            }

            filename
        }
    }

    private fun queryMetadata(context: Context, uri: Uri): Pair<String, Long> {
        var name = "shared_file"
        var size = 0L
        context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIdx >= 0) name = cursor.getString(nameIdx) ?: name
                if (sizeIdx >= 0) size = cursor.getLong(sizeIdx)
            }
        }
        return name to size
    }
}
