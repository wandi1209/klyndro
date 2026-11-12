package id.my.wandidev.klyndro.connection

import com.google.gson.JsonObject
import id.my.wandidev.klyndro.protocol.Envelope
import id.my.wandidev.klyndro.protocol.MessageType
import java.io.File
import java.io.IOException

/**
 * Answers `mirror.challenge` (protocol §5.4a): writes the token into the app's own external files
 * directory so the Mac can read it back over adb and confirm the adb device and this authenticated
 * session are the same phone. Writes only a token that is exactly 32 lowercase hex characters.
 */
class MirrorProofResponder(
    private val directory: () -> File?,
    private val scheduleCleanup: (File) -> Unit = {}
) {
    /** Returns the reply to send, or null when the challenge must be ignored. */
    fun respond(envelope: Envelope): Envelope? {
        if (envelope.messageType != MessageType.MIRROR_CHALLENGE) return null
        val token = envelope.body?.get("token")?.takeIf { it.isJsonPrimitive }?.asString ?: return null
        if (!TOKEN.matches(token)) return null

        val ok = write(token)
        return Envelope.create(MessageType.MIRROR_PROOF, JsonObject().apply {
            addProperty("token", token)
            addProperty("ok", ok)
        })
    }

    private fun write(token: String): Boolean {
        val dir = directory() ?: return false
        return try {
            dir.mkdirs()
            val file = File(dir, FILE_NAME)
            file.writeText(token)
            scheduleCleanup(file)
            true
        } catch (_: IOException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    companion object {
        const val FILE_NAME = "klyndro-mirror-proof"
        private val TOKEN = Regex("^[0-9a-f]{32}$")
    }
}
