package id.my.wandidev.klyndro.connection

import id.my.wandidev.klyndro.protocol.PairingFailure
import kotlinx.coroutines.CancellationException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ConnectException
import java.net.SocketTimeoutException
import javax.net.ssl.SSLHandshakeException

class UserErrorFormatterTest {

    @Test
    fun `maps pairing failures to plain messages without wire codes`() {
        for (reason in PairingFailure.entries) {
            val formatted = UserErrorFormatter.formatPairingFailure(reason)
            assertTrue(formatted.isNotBlank())
            assertFalse(formatted.contains("_"))
        }
    }

    @Test
    fun `maps socket and tls exceptions without leaking technical jargon`() {
        val refused = UserErrorFormatter.formatConnectionError(
            ConnectException("failed to connect to /192.168.23.101 (port 47823): ECONNREFUSED")
        )!!
        assertTrue(refused.contains("Make sure Klyndro is open"))
        assertFalse(refused.contains("ECONNREFUSED"))
        assertFalse(refused.contains("192.168"))

        val timeout = UserErrorFormatter.formatConnectionError(SocketTimeoutException("Read timed out"))!!
        assertTrue(timeout.contains("timed out"))

        val ssl = UserErrorFormatter.formatConnectionError(SSLHandshakeException("CERTIFICATE_VERIFY_FAILED"))!!
        assertTrue(ssl.contains("pairing again"))

        assertNull(UserErrorFormatter.formatConnectionError(CancellationException("cancelled")))
    }
}
