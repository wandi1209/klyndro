package id.my.wandidev.klyndro.net

import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader

/**
 * Decodes a QR code from a camera frame's Y (luminance) plane without any network or Play Services
 * dependency. Pure enough to test on the JVM.
 */
object QrLuminanceDecoder {

    private val hints = mapOf(
        DecodeHintType.TRY_HARDER to true,
        DecodeHintType.CHARACTER_SET to "UTF-8"
    )

    fun decodeYPlane(
        yPlane: ByteArray,
        width: Int,
        height: Int,
        rowStride: Int = width
    ): String? {
        if (width <= 0 || height <= 0 || rowStride < width) return null
        if (yPlane.size < (height - 1) * rowStride + width) return null

        val compact = if (rowStride == width) {
            yPlane
        } else {
            ByteArray(width * height).also { dst ->
                for (row in 0 until height) {
                    System.arraycopy(yPlane, row * rowStride, dst, row * width, width)
                }
            }
        }

        val source = PlanarYUVLuminanceSource(
            compact,
            width,
            height,
            0,
            0,
            width,
            height,
            false
        )
        val bitmap = BinaryBitmap(HybridBinarizer(source))
        return try {
            QRCodeReader().decode(bitmap, hints).text
        } catch (_: ReaderException) {
            null
        }
    }
}
