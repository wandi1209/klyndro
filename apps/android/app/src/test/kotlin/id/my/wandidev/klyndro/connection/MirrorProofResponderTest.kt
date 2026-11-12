package id.my.wandidev.klyndro.connection

import com.google.gson.JsonObject
import id.my.wandidev.klyndro.protocol.Envelope
import id.my.wandidev.klyndro.protocol.MessageType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MirrorProofResponderTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val token = "9f3a1c5e7b2d4086a1b3c5d7e9f02468"

    private fun challenge(value: String?): Envelope = Envelope.create(
        MessageType.MIRROR_CHALLENGE,
        JsonObject().apply { if (value != null) addProperty("token", value) }
    )

    @Test
    fun `a valid challenge writes the token and answers ok`() {
        val dir = tmp.newFolder("files")
        val reply = MirrorProofResponder({ dir }).respond(challenge(token))

        assertNotNull(reply)
        assertEquals(MessageType.MIRROR_PROOF, reply!!.messageType)
        assertEquals(token, reply.body!!.get("token").asString)
        assertTrue(reply.body!!.get("ok").asBoolean)
        assertEquals(token, java.io.File(dir, MirrorProofResponder.FILE_NAME).readText())
    }

    @Test
    fun `a malformed token is ignored and writes nothing`() {
        val dir = tmp.newFolder("files")
        val responder = MirrorProofResponder({ dir })
        for (bad in listOf("", "short", token.uppercase(), token + "0", "../../etc/passwd", "g".repeat(32))) {
            assertNull("token '$bad'", responder.respond(challenge(bad)))
        }
        assertNull(responder.respond(challenge(null)))
        assertFalse(java.io.File(dir, MirrorProofResponder.FILE_NAME).exists())
    }

    @Test
    fun `no storage directory answers ok false`() {
        val reply = MirrorProofResponder({ null }).respond(challenge(token))
        assertNotNull(reply)
        assertFalse(reply!!.body!!.get("ok").asBoolean)
        assertEquals(token, reply.body!!.get("token").asString)
    }

    @Test
    fun `an unwritable directory answers ok false`() {
        val blocker = tmp.newFile("not-a-directory")
        val reply = MirrorProofResponder({ blocker }).respond(challenge(token))
        assertNotNull(reply)
        assertFalse(reply!!.body!!.get("ok").asBoolean)
    }

    @Test
    fun `other message types are ignored`() {
        val dir = tmp.newFolder("files")
        val ping = Envelope.create(MessageType.PING, JsonObject().apply { addProperty("nonce", "x") })
        assertNull(MirrorProofResponder({ dir }).respond(ping))
    }

    @Test
    fun `cleanup is scheduled for the written file`() {
        val dir = tmp.newFolder("files")
        var scheduled: java.io.File? = null
        MirrorProofResponder({ dir }, { scheduled = it }).respond(challenge(token))
        assertEquals(MirrorProofResponder.FILE_NAME, scheduled?.name)
    }
}
