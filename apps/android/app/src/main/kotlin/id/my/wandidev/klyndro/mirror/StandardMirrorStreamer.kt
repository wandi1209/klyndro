package id.my.wandidev.klyndro.mirror

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.os.Build
import android.util.Log
import android.view.Surface
import androidx.core.content.ContextCompat
import id.my.wandidev.klyndro.crypto.DeviceIdentity
import id.my.wandidev.klyndro.net.PinPolicy
import id.my.wandidev.klyndro.net.TlsConfiguration
import id.my.wandidev.klyndro.protocol.MirrorStreamStartBody
import id.my.wandidev.klyndro.protocol.VideoStreamPacketCodec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.OutputStream
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import javax.net.ssl.SSLSocket

/**
 * Streams H.264 Annex-B video (and optional 48 kHz stereo PCM playback audio via
 * `AudioPlaybackCapture`) from a user-approved [MediaProjection] to the Mac's pinned
 * mutual-TLS 1.3 media listener (ADR 0010, protocol §5.6).
 */
class StandardMirrorStreamer(
    private val context: Context,
    private val mediaProjection: MediaProjection,
    private val sourceWidth: Int,
    private val sourceHeight: Int,
    private val densityDpi: Int,
    private val host: String,
    private val request: MirrorStreamStartBody,
    private val identity: DeviceIdentity,
    private val policy: PinPolicy,
    private val onStopped: (String?) -> Unit
) {
    private var job: Job? = null
    private var audioJob: Job? = null
    @Volatile
    private var stopped = false
    private var socket: SSLSocket? = null
    private var codec: MediaCodec? = null
    private var audioRecord: AudioRecord? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var inputSurface: Surface? = null
    private val writeLock = Any()

    fun start(scope: CoroutineScope) {
        if (job != null) return
        job = scope.launch(Dispatchers.IO) {
            var errorReason: String? = null
            try {
                runStream(this)
            } catch (err: Exception) {
                if (!stopped) {
                    Log.w(TAG, "standard mirror stream ended: ${err.message}")
                    errorReason = err.message ?: "stream_error"
                }
            } finally {
                cleanup()
                if (!stopped) {
                    stopped = true
                    onStopped(errorReason)
                }
            }
        }
    }

    fun stop() {
        if (stopped) return
        stopped = true
        audioJob?.cancel()
        audioJob = null
        job?.cancel()
        cleanup()
    }

    private fun runStream(scope: CoroutineScope) {
        val (width, height) = VideoStreamPacketCodec.scaledDimensions(
            sourceWidth = sourceWidth,
            sourceHeight = sourceHeight,
            maxWidth = request.maxWidth
        )

        val sslContext = TlsConfiguration.context(identity, policy)
        val sslSocket = sslContext.socketFactory.createSocket() as SSLSocket
        TlsConfiguration.configure(sslSocket, needClientAuth = false)
        sslSocket.connect(InetSocketAddress(host, request.port), CONNECT_TIMEOUT_MILLIS)
        sslSocket.startHandshake()
        socket = sslSocket

        val out = sslSocket.getOutputStream()
        synchronized(writeLock) {
            out.write(request.streamId.lowercase().toByteArray(StandardCharsets.US_ASCII))
            out.flush()
        }

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
            )
            setInteger(MediaFormat.KEY_BIT_RATE, request.bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, request.fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }

        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec = encoder
        encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = encoder.createInputSurface()
        inputSurface = surface
        encoder.start()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            mediaProjection.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    stop()
                }
            }, null)
        }

        virtualDisplay = mediaProjection.createVirtualDisplay(
            "KlyndroStandardMirror",
            width,
            height,
            densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            surface,
            null,
            null
        )

        if (request.audio) {
            startAudioCaptureIfPermitted(scope, out)
        }

        val info = MediaCodec.BufferInfo()
        while (scope.isActive && !stopped) {
            val index = encoder.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
            if (index >= 0) {
                val buf = encoder.getOutputBuffer(index)
                if (buf != null && info.size > 0) {
                    val bytes = ByteArray(info.size)
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    buf.get(bytes)

                    val flags: Byte = when {
                        (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0 ->
                            VideoStreamPacketCodec.FLAG_CONFIG
                        (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0 ->
                            VideoStreamPacketCodec.FLAG_KEY_FRAME
                        else -> 0
                    }
                    val packet = VideoStreamPacketCodec.encode(flags, info.presentationTimeUs, bytes)
                    synchronized(writeLock) {
                        out.write(packet)
                        out.flush()
                    }
                }
                encoder.releaseOutputBuffer(index, false)
            } else if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                continue
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun startAudioCaptureIfPermitted(scope: CoroutineScope, out: OutputStream) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val granted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            Log.i(TAG, "Standard audio requested but RECORD_AUDIO is not granted; streaming video only")
            return
        }

        val config = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()

        val audioFormat = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(AUDIO_SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()

        val minBuf = AudioRecord.getMinBufferSize(
            AUDIO_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        ).coerceAtLeast(AUDIO_CHUNK_BYTES * 2)

        val recorder = runCatching {
            AudioRecord.Builder()
                .setAudioFormat(audioFormat)
                .setBufferSizeInBytes(minBuf)
                .setAudioPlaybackCaptureConfig(config)
                .build()
        }.getOrNull() ?: return

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            runCatching { recorder.release() }
            return
        }

        audioRecord = recorder
        audioJob = scope.launch(Dispatchers.IO) {
            val buffer = ByteArray(AUDIO_CHUNK_BYTES)
            runCatching {
                recorder.startRecording()
                while (isActive && !stopped) {
                    val read = recorder.read(buffer, 0, buffer.size)
                    if (read > 0) {
                        val payload = if (read == buffer.size) buffer else buffer.copyOf(read)
                        val ptsUs = System.nanoTime() / 1_000L
                        val packet = VideoStreamPacketCodec.encode(
                            VideoStreamPacketCodec.FLAG_AUDIO_PCM,
                            ptsUs,
                            payload
                        )
                        synchronized(writeLock) {
                            out.write(packet)
                            out.flush()
                        }
                    }
                }
            }
        }
    }

    private fun cleanup() {
        runCatching {
            audioRecord?.stop()
            audioRecord?.release()
        }
        audioRecord = null
        runCatching { virtualDisplay?.release() }
        virtualDisplay = null
        runCatching {
            codec?.stop()
            codec?.release()
        }
        codec = null
        runCatching { inputSurface?.release() }
        inputSurface = null
        runCatching { mediaProjection.stop() }
        runCatching { socket?.close() }
        socket = null
    }

    companion object {
        private const val TAG = "KlyndroStdMirror"
        private const val CONNECT_TIMEOUT_MILLIS = 10_000
        private const val DEQUEUE_TIMEOUT_US = 20_000L
        private const val AUDIO_SAMPLE_RATE = 48_000
        private const val AUDIO_CHUNK_BYTES = 3_840 // 20 ms stereo 16-bit PCM @ 48 kHz
    }
}
