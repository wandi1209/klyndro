package id.my.wandidev.klyndro.net

import id.my.wandidev.klyndro.crypto.Fingerprint
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PairingQRCodeTest {

    private val fpHex = "ab".repeat(32)
    private val fp = Fingerprint.parse(fpHex)!!

    @Test
    fun `parses valid pairing QR URI with percent-encoded name`() {
        val raw = "klyndro://pair?v=1&host=192.168.23.101&port=47823&fp=$fpHex&name=Wandi%20MacBook"
        val parsed = PairingQRCodePayloadCheck.parse(raw)
        assertEquals(PairingQRPayload("192.168.23.101", 47823, fp, "Wandi MacBook"), parsed)
    }

    @Test
    fun `normalises uppercase fingerprint hex and omits absent name`() {
        val raw = "klyndro://pair?v=1&host=192.168.1.20&port=47823&fp=${"AB".repeat(32)}"
        val parsed = PairingQRPayload.parse(raw)
        assertEquals(PairingQRPayload("192.168.1.20", 47823, fp, null), parsed)
    }

    @Test
    fun `rejects wrong scheme, version, host, port, and fingerprint`() {
        val bad = listOf(
            "",
            "https://example.com?v=1&host=192.168.1.1&port=47823&fp=$fpHex",
            "klyndro://mirror?v=1&host=192.168.1.1&port=47823&fp=$fpHex",
            "klyndro://pair?v=2&host=192.168.1.1&port=47823&fp=$fpHex",
            "klyndro://pair?v=1&host=192.168.1.1&port=0&fp=$fpHex",
            "klyndro://pair?v=1&host=192.168.1.1&port=70000&fp=$fpHex",
            "klyndro://pair?v=1&host=&port=47823&fp=$fpHex",
            "klyndro://pair?v=1&host=192.168.1.1&port=47823&fp=deadbeef"
        )
        for (raw in bad) {
            assertNull("expected rejection for $raw", PairingQRPayload.parse(raw))
        }
    }
}

private typealias PairingQRCodePayloadCheck = PairingQRPayload
