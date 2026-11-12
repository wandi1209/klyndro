package id.my.wandidev.klyndro.filetransfer

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import id.my.wandidev.klyndro.protocol.Envelope
import id.my.wandidev.klyndro.protocol.FileAcceptBody
import id.my.wandidev.klyndro.protocol.FileChunkBody
import id.my.wandidev.klyndro.protocol.FileCompleteBody
import id.my.wandidev.klyndro.protocol.FileMessageCodec
import id.my.wandidev.klyndro.protocol.FileMessageException
import id.my.wandidev.klyndro.protocol.FileRejectBody
import id.my.wandidev.klyndro.protocol.MessageType
import java.io.OutputStream

/**
 * Saves into `Downloads/Klyndro` through MediaStore. On API 29+ an app may create files in its own
 * MediaStore entries without any storage permission, which is why none is requested.
 */
class MediaStoreSink(private val context: Context) : FileSink {
    private var uri: Uri? = null

    override fun open(displayName: String, mimeType: String): OutputStream? {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Klyndro")
            // Hidden from other apps until the hash has been verified.
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val created = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: return null
        val stream = runCatching { context.contentResolver.openOutputStream(created) }.getOrNull()
        if (stream == null) {
            context.contentResolver.delete(created, null, null)
            return null
        }
        uri = created
        return stream
    }

    override fun commit(): String? {
        val target = uri ?: return null
        val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
        context.contentResolver.update(target, values, null, null)
        val name = context.contentResolver.query(
            target, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null
        )?.use { if (it.moveToFirst()) it.getString(0) else null }
        uri = null
        return name
    }

    override fun discard() {
        uri?.let { runCatching { context.contentResolver.delete(it, null, null) } }
        uri = null
    }
}

/**
 * Turns `file.*` envelopes from the Mac into a [FileReceiveSession] and sends the replies.
 * Only the service calls this, on its IO scope; replies go back through the active session.
 */
class AndroidFileReceiver(
    context: Context,
    private val send: suspend (Envelope) -> Boolean,
    private val onSaved: (String) -> Unit
) {
    private val session = FileReceiveSession(newSink = { MediaStoreSink(context.applicationContext) })

    suspend fun handle(envelope: Envelope) {
        val body = envelope.body ?: return
        try {
            when (envelope.messageType) {
                MessageType.FILE_OFFER -> {
                    val offer = FileMessageCodec.decodeOffer(envelope)
                    when (val decision = session.onOffer(offer)) {
                        OfferDecision.Accept -> send(reply(MessageType.FILE_ACCEPT, FileAcceptBody(offer.transferId).toJson()))
                        is OfferDecision.Reject ->
                            send(reply(MessageType.FILE_REJECT, FileRejectBody(offer.transferId, decision.reason).toJson()))
                    }
                }
                MessageType.FILE_CHUNK -> session.onChunk(FileChunkBody.fromJson(body))
                MessageType.FILE_COMPLETE -> {
                    when (val result = session.onComplete(FileCompleteBody.fromJson(body))) {
                        is ReceiveResult.Saved -> onSaved(result.displayName)
                        // Reason only; never the file name or any content.
                        is ReceiveResult.Failed -> android.util.Log.w(TAG, "file receive failed: ${result.reason}")
                    }
                }
                else -> Unit
            }
        } catch (e: FileMessageException) {
            // A malformed file message is dropped; it must not take the session down.
            android.util.Log.w(TAG, "ignored malformed file message: ${e.message}")
            session.abort()
        }
    }

    /** Called when the connection closes, so a half-written file does not linger. */
    fun abort() = session.abort()

    private fun reply(type: MessageType, body: com.google.gson.JsonObject): Envelope =
        Envelope.create(type, body)

    private companion object {
        const val TAG = "KlyndroFileReceive"
    }
}
