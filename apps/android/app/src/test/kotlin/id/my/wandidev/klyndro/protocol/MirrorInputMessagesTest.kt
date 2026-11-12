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
}
