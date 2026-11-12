package id.my.wandidev.klyndro.protocol

import com.google.gson.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MirrorInputMessagesTest {

    @Test
    fun `round trips tap, swipe, and action`() {
        val tap = InputGestureBody(InputGestureKind.TAP, 0.25f, 0.75f)
        assertEquals(tap, InputGestureBody.decode(tap.toEnvelope()))

        val swipe = InputGestureBody(InputGestureKind.SWIPE, 0.5f, 0.8f, 0.5f, 0.2f, 220)
        assertEquals(swipe, InputGestureBody.decode(swipe.toEnvelope()))

        val action = InputActionBody(InputActionKind.HOME)
        assertEquals(action, InputActionBody.decode(action.toEnvelope()))
    }

    @Test
    fun `rejects out-of-range coordinates and unknown actions`() {
        val badCoord = InputGestureBody(InputGestureKind.TAP, 1.5f, 0.5f).toEnvelope()
        assertNull(InputGestureBody.decode(badCoord))

        val incompleteSwipe = Envelope.create(
            MessageType.INPUT_GESTURE,
            JsonObject().apply {
                addProperty("kind", "swipe")
                addProperty("x", 0.5)
                addProperty("y", 0.8)
                addProperty("duration_ms", 200)
            }
        )
        assertNull(InputGestureBody.decode(incompleteSwipe))

        val unknownAction = Envelope.create(
            MessageType.INPUT_ACTION,
            JsonObject().apply { addProperty("action", "reboot") }
        )
        assertNull(InputActionBody.decode(unknownAction))
    }

    @Test
    fun `round trips input text and rejects oversized or empty append`() {
        val append = InputTextBody(InputTextMode.APPEND, "hello")
        assertEquals(append, InputTextBody.decode(append.toEnvelope()))

        val backspace = InputTextBody(InputTextMode.BACKSPACE, "")
        assertEquals(backspace, InputTextBody.decode(backspace.toEnvelope()))

        assertNull(InputTextBody.decode(InputTextBody(InputTextMode.APPEND, "").toEnvelope()))
        assertNull(
            InputTextBody.decode(
                InputTextBody(InputTextMode.REPLACE, "a".repeat(InputTextBody.MAX_UTF8_BYTES + 1)).toEnvelope()
            )
        )
    }

    @Test
    fun `encodes app list and validates app launch package names`() {
        val listEnv = AppLauncherMessages.listEnvelope(
            listOf(
                StandardAppEntry("id.my.wandidev.klyndro", "Klyndro"),
                StandardAppEntry("bad;rm", "Evil")
            )
        )
        val arr = listEnv.body!!.getAsJsonArray("apps")
        assertEquals(1, arr.size())
        assertEquals("id.my.wandidev.klyndro", arr[0].asJsonObject.get("package").asString)

        val validLaunch = Envelope.create(
            MessageType.APP_LAUNCH,
            JsonObject().apply { addProperty("package", "id.my.wandidev.klyndro") }
        )
        assertEquals("id.my.wandidev.klyndro", AppLauncherMessages.decodeLaunch(validLaunch))

        val badLaunch = Envelope.create(
            MessageType.APP_LAUNCH,
            JsonObject().apply { addProperty("package", "bad;rm") }
        )
        assertNull(AppLauncherMessages.decodeLaunch(badLaunch))
    }
}
