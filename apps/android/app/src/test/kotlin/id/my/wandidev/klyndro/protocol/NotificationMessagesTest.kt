package id.my.wandidev.klyndro.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Test

class NotificationMessagesTest {

    private fun sample() = NotificationPostBody(
        key = "com.example.chat:100:1762800000",
        packageName = "com.example.chat",
        appName = "ChatApp",
        title = "Alice",
        text = "Hello from phone!",
        postedAt = 1762800000L,
        sensitive = false
    )

    @Test
    fun roundTripsNotificationPost() {
        val original = sample()
        val envelope = NotificationMessageCodec.postEnvelope(original)
        assertEquals(MessageType.NOTIFICATION_POST, envelope.messageType)

        val decoded = NotificationMessageCodec.decodePost(envelope)
        assertEquals(original, decoded)
    }

    @Test(expected = NotificationMessageException.PayloadTooLarge::class)
    fun rejectsOversizedTitle() {
        val longTitle = "A".repeat(1025)
        val body = sample().copy(title = longTitle)
        NotificationMessageCodec.postEnvelope(body)
    }

    @Test(expected = NotificationMessageException.PayloadTooLarge::class)
    fun rejectsOversizedText() {
        val longText = "T".repeat(8193)
        val body = sample().copy(text = longText)
        NotificationMessageCodec.postEnvelope(body)
    }

    @Test(expected = NotificationMessageException.NotANotificationMessage::class)
    fun refusesNonNotificationEnvelope() {
        val env = Envelope(
            v = 1,
            id = "test-id",
            type = MessageType.PING.wireName!!,
            ts = System.currentTimeMillis(),
            body = null
        )
        NotificationMessageCodec.decodePost(env)
    }
}
