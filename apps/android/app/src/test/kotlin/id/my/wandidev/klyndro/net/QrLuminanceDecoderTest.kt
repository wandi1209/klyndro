package id.my.wandidev.klyndro.net

import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QrLuminanceDecoderTest {

    @Test
    fun `decodes a generated pairing QR from Y-plane luminance bytes`() {
        val uri = "klyndro://pair?v=1&host=192.168.23.101&port=47823&fp=${"ab".repeat(32)}&name=Mac"
        val size = 240
        val matrix = QRCodeWriter().encode(uri, BarcodeFormat.QR_CODE, size, size)
        val yPlane = ByteArray(size * size) { index ->
            val x = index % size
            val y = index / size
            if (matrix.get(x, y)) 0x10.toByte() else 0xF0.toByte()
        }

        assertEquals(uri, QrLuminanceDecoder.decodeYPlane(yPlane, size, size))
    }

    @Test
    fun `handles padded rowStride and rejects invalid dimensions`() {
        val uri = "klyndro://pair?v=1&host=10.0.0.5&port=47823&fp=${"cd".repeat(32)}"
        val size = 200
        val stride = 224
        val matrix = QRCodeWriter().encode(uri, BarcodeFormat.QR_CODE, size, size)
        val padded = ByteArray(size * stride) { 0xF0.toByte() }
        for (y in 0 until size) {
            for (x in 0 until size) {
                padded[y * stride + x] = if (matrix.get(x, y)) 0x10.toByte() else 0xF0.toByte()
            }
        }

        assertEquals(uri, QrLuminanceDecoder.decodeYPlane(padded, size, size, stride))
        assertNull(QrLuminanceDecoder.decodeYPlane(ByteArray(10), 0, 10))
        assertNull(QrLuminanceDecoder.decodeYPlane(ByteArray(10), 10, 10, 8))
    }
}
