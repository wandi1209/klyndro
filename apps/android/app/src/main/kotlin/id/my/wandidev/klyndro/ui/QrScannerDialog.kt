package id.my.wandidev.klyndro.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import android.view.TextureView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import id.my.wandidev.klyndro.R
import id.my.wandidev.klyndro.net.PairingQRPayload
import id.my.wandidev.klyndro.net.QrLuminanceDecoder
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Offline QR scanner backed by platform `Camera2` and `QrLuminanceDecoder`.
 */
@Composable
fun QrScannerDialog(
    onScanned: (PairingQRPayload) -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    var cameraError by remember { mutableStateOf<String?>(null) }
    val handled = remember { AtomicBoolean(false) }

    val controller = remember {
        CameraQrController(
            context = context,
            onPayload = { payload ->
                if (handled.compareAndSet(false, true)) {
                    onScanned(payload)
                }
            },
            onError = { message -> cameraError = message }
        )
    }

    DisposableEffect(controller) {
        onDispose { controller.close() }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.qr_scan_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    text = cameraError ?: stringResource(R.string.qr_scan_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = if (cameraError != null) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    }
                )
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(3f / 4f)
                        .clip(RoundedCornerShape(12.dp))
                ) {
                    AndroidView(
                        modifier = Modifier.fillMaxSize(),
                        factory = { ctx ->
                            TextureView(ctx).apply {
                                surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                                    override fun onSurfaceTextureAvailable(
                                        surface: SurfaceTexture,
                                        width: Int,
                                        height: Int
                                    ) {
                                        controller.start(surface)
                                    }

                                    override fun onSurfaceTextureSizeChanged(
                                        surface: SurfaceTexture,
                                        width: Int,
                                        height: Int
                                    ) = Unit

                                    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
                                        controller.close()
                                        return true
                                    }

                                    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
                                }
                            }
                        }
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.pairing_cancel))
            }
        }
    )
}

private class CameraQrController(
    private val context: Context,
    private val onPayload: (PairingQRPayload) -> Unit,
    private val onError: (String) -> Unit
) {
    private val mainHandler = Handler(context.mainLooper)
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var cameraDevice: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var previewSurface: Surface? = null
    private var lastDecodeMillis = 0L
    @Volatile
    private var closed = false

    @SuppressLint("MissingPermission")
    fun start(surfaceTexture: SurfaceTexture) {
        if (closed || cameraDevice != null) return
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        if (manager == null) {
            onError("Camera service unavailable.")
            return
        }
        val cameraId = selectCameraId(manager)
        if (cameraId == null) {
            onError("No camera found on this device.")
            return
        }

        val worker = HandlerThread("KlyndroQrScanner").apply { start() }
        thread = worker
        val bgHandler = Handler(worker.looper)
        handler = bgHandler

        surfaceTexture.setDefaultBufferSize(PREVIEW_WIDTH, PREVIEW_HEIGHT)
        val surface = Surface(surfaceTexture)
        previewSurface = surface

        val reader = ImageReader.newInstance(
            PREVIEW_WIDTH,
            PREVIEW_HEIGHT,
            ImageFormat.YUV_420_888,
            2
        ).apply {
            setOnImageAvailableListener({ r -> processFrame(r) }, bgHandler)
        }
        imageReader = reader

        runCatching {
            manager.openCamera(
                cameraId,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(camera: CameraDevice) {
                        if (closed) {
                            camera.close()
                            return
                        }
                        cameraDevice = camera
                        startCaptureSession(camera, surface, reader.surface, bgHandler)
                    }

                    override fun onDisconnected(camera: CameraDevice) {
                        camera.close()
                        cameraDevice = null
                    }

                    override fun onError(camera: CameraDevice, error: Int) {
                        camera.close()
                        cameraDevice = null
                        mainHandler.post { onError("Could not open camera (error $error).") }
                    }
                },
                bgHandler
            )
        }.onFailure { err ->
            mainHandler.post { onError(err.message ?: "Could not open camera.") }
        }
    }

    private fun startCaptureSession(
        camera: CameraDevice,
        preview: Surface,
        analysis: Surface,
        bgHandler: Handler
    ) {
        val targets = listOf(preview, analysis)
        runCatching {
            @Suppress("DEPRECATION")
            camera.createCaptureSession(
                targets,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(captureSession: CameraCaptureSession) {
                        if (closed) {
                            captureSession.close()
                            return
                        }
                        session = captureSession
                        val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                            addTarget(preview)
                            addTarget(analysis)
                        }.build()
                        runCatching { captureSession.setRepeatingRequest(request, null, bgHandler) }
                    }

                    override fun onConfigureFailed(captureSession: CameraCaptureSession) {
                        mainHandler.post { onError("Camera preview failed to start.") }
                    }
                },
                bgHandler
            )
        }.onFailure { err ->
            mainHandler.post { onError(err.message ?: "Camera session failed.") }
        }
    }

    private fun processFrame(reader: ImageReader) {
        val image = reader.acquireLatestImage() ?: return
        try {
            val now = System.currentTimeMillis()
            if (now - lastDecodeMillis < DECODE_INTERVAL_MILLIS) return
            lastDecodeMillis = now

            val yPlane = image.planes.firstOrNull() ?: return
            val buffer = yPlane.buffer
            val bytes = ByteArray(buffer.remaining())
            buffer.get(bytes)

            val raw = QrLuminanceDecoder.decodeYPlane(
                yPlane = bytes,
                width = image.width,
                height = image.height,
                rowStride = yPlane.rowStride
            ) ?: return

            val payload = PairingQRPayload.parse(raw) ?: return
            mainHandler.post { onPayload(payload) }
        } finally {
            image.close()
        }
    }

    fun close() {
        if (closed) return
        closed = true
        runCatching { session?.close() }
        session = null
        runCatching { cameraDevice?.close() }
        cameraDevice = null
        runCatching { imageReader?.close() }
        imageReader = null
        runCatching { previewSurface?.release() }
        previewSurface = null
        thread?.quitSafely()
        thread = null
        handler = null
    }

    private fun selectCameraId(manager: CameraManager): String? {
        val ids = runCatching { manager.cameraIdList }.getOrNull() ?: return null
        return ids.firstOrNull { id ->
            val facing = manager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING)
            facing == CameraCharacteristics.LENS_FACING_BACK
        } ?: ids.firstOrNull()
    }

    private companion object {
        const val PREVIEW_WIDTH = 640
        const val PREVIEW_HEIGHT = 480
        const val DECODE_INTERVAL_MILLIS = 150L
    }
}
