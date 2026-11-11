package id.my.wandidev.klyndro.net

import id.my.wandidev.klyndro.crypto.DeviceIdentity
import id.my.wandidev.klyndro.crypto.Fingerprint
import id.my.wandidev.klyndro.protocol.Frame
import id.my.wandidev.klyndro.protocol.FrameDecoder
import id.my.wandidev.klyndro.protocol.FrameEncoder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.security.KeyStore
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509ExtendedTrustManager

/** Bidirectional frame channel. Narrow so the session logic is testable without sockets. */
interface FrameTransport {
    suspend fun send(frame: Frame)

    /** Next frame, or `null` when the peer closed or the connection failed. */
    suspend fun receive(): Frame?

    fun close()

    /** Peer key fingerprint as proven by the TLS handshake, if available. */
    fun peerFingerprint(): Fingerprint?
}

/** In-memory pair of transports for tests. */
class InMemoryFrameTransport private constructor(
    private val incoming: Channel<Frame>,
    private val outgoing: Channel<Frame>
) : FrameTransport {

    @Volatile
    var peerFingerprintValue: Fingerprint? = null

    override suspend fun send(frame: Frame) {
        outgoing.trySend(frame).getOrThrow()
    }

    override suspend fun receive(): Frame? = incoming.receiveCatching().getOrNull()

    override fun close() {
        outgoing.close()
        incoming.close()
    }

    override fun peerFingerprint(): Fingerprint? = peerFingerprintValue

    companion object {
        fun pair(): Pair<InMemoryFrameTransport, InMemoryFrameTransport> {
            val clientToServer = Channel<Frame>(Channel.UNLIMITED)
            val serverToClient = Channel<Frame>(Channel.UNLIMITED)
            return InMemoryFrameTransport(serverToClient, clientToServer) to
                InMemoryFrameTransport(clientToServer, serverToClient)
        }
    }
}

/** TCP + TLS 1.3 framing over a socket. */
class SocketFrameTransport(
    private val socket: Socket,
    scope: CoroutineScope
) : FrameTransport {

    private val frames = Channel<Frame>(Channel.UNLIMITED)
    private val decoder = FrameDecoder()
    private val writeMutex = Mutex()
    private val decoderMutex = Mutex()

    init {
        scope.launch(Dispatchers.IO) { readLoop() }
    }

    override suspend fun send(frame: Frame) {
        val bytes = FrameEncoder.encode(frame)
        withContext(Dispatchers.IO) {
            writeMutex.withLock {
                try {
                    socket.getOutputStream().write(bytes)
                    socket.getOutputStream().flush()
                } catch (error: IOException) {
                    throw IllegalStateException("transport closed", error)
                }
            }
        }
    }

    override suspend fun receive(): Frame? = frames.receiveCatching().getOrNull()

    override fun close() {
        runCatching { socket.close() }
        frames.close()
    }

    override fun peerFingerprint(): Fingerprint? {
        val certificate = (socket as? SSLSocket)?.session?.peerCertificates?.firstOrNull()
            as? X509Certificate ?: return null
        return PinPolicy.fingerprintOf(certificate)
    }

    private suspend fun readLoop() {
        val buffer = ByteArray(16 * 1024)
        try {
            while (true) {
                val read = socket.getInputStream().read(buffer)
                if (read < 0) break
                if (read == 0) continue

                decoderMutex.withLock {
                    decoder.append(buffer.copyOf(read))
                    while (true) {
                        val frame = decoder.nextFrame() ?: break
                        frames.trySend(frame)
                    }
                }
            }
        } catch (_: IOException) {
            // Peer closed or reset; treated the same as a clean close by the session.
        } catch (_: Exception) {
            // Protocol violation while decoding: the session sees a closed transport.
        } finally {
            frames.close()
        }
    }
}

/** TLS 1.3 setup shared by the listener and the dialer. */
object TlsConfiguration {
    private val password = CharArray(0)

    fun context(identity: DeviceIdentity, policy: PinPolicy): SSLContext {
        val keyStore = KeyStore.getInstance("PKCS12")
        keyStore.load(null, null)
        keyStore.setKeyEntry("klyndro", identity.privateKey, password, arrayOf(identity.certificate))

        val keyManagerFactory = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        keyManagerFactory.init(keyStore, password)

        val context = SSLContext.getInstance("TLSv1.3")
        context.init(
            keyManagerFactory.keyManagers,
            arrayOf<TrustManager>(PinningTrustManager(policy)),
            SecureRandom()
        )
        return context
    }

    fun configure(socket: SSLSocket, needClientAuth: Boolean) {
        socket.enabledProtocols = arrayOf("TLSv1.3")
        if (needClientAuth) socket.needClientAuth = true
    }
}

/**
 * Trust manager that ignores the system chain and decides purely on the pinned fingerprint.
 *
 * Every Klyndro certificate is self-signed, so system validation would reject all of them;
 * what we trust is a previously pinned public key (protocol §2, ADR 0002).
 */
class PinningTrustManager(private val policy: PinPolicy) : X509ExtendedTrustManager() {

    private fun verify(chain: Array<out X509Certificate>?) {
        val leaf = chain?.firstOrNull()
            ?: throw java.security.cert.CertificateException("no peer certificate")
        when (val decision = policy.evaluate(leaf.encoded)) {
            is PinDecision.Accepted -> Unit
            is PinDecision.Rejected -> throw java.security.cert.CertificateException(
                "peer certificate is not trusted (${decision.reason})"
            )
        }
    }

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = verify(chain)
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = verify(chain)
    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) = verify(chain)
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) = verify(chain)
    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: javax.net.ssl.SSLEngine?) = verify(chain)
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: javax.net.ssl.SSLEngine?) = verify(chain)

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

/** Accepts connections with mutual TLS. */
class TlsServer(
    identity: DeviceIdentity,
    policy: PinPolicy,
    private val onConnection: (SocketFrameTransport) -> Unit
) : AutoCloseable {

    private val serverSocket: SSLServerSocket

    val port: Int

    init {
        val context = TlsConfiguration.context(identity, policy)
        serverSocket = context.serverSocketFactory.createServerSocket(0) as SSLServerSocket
        serverSocket.needClientAuth = true
        serverSocket.enabledProtocols = arrayOf("TLSv1.3")
        port = serverSocket.localPort
    }

    fun start(scope: CoroutineScope) {
        scope.launch(Dispatchers.IO) {
            while (isActive) {
                val accepted = try {
                    serverSocket.accept()
                } catch (_: IOException) {
                    break
                }
                val socket = accepted as SSLSocket
                try {
                    // Completes the handshake here so a rejected certificate never reaches the
                    // session layer.
                    socket.startHandshake()
                } catch (_: Exception) {
                    runCatching { socket.close() }
                    continue
                }
                onConnection(SocketFrameTransport(socket, scope))
            }
        }
    }

    override fun close() {
        runCatching { serverSocket.close() }
    }
}

/** Connects and completes the TLS handshake. */
object TlsClient {
    suspend fun connect(
        host: String,
        port: Int,
        identity: DeviceIdentity,
        policy: PinPolicy,
        scope: CoroutineScope,
        timeoutMillis: Int = 10_000
    ): SocketFrameTransport = withContext(Dispatchers.IO) {
        val context = TlsConfiguration.context(identity, policy)
        val socket = context.socketFactory.createSocket() as SSLSocket
        socket.connect(InetSocketAddress(host, port), timeoutMillis)
        TlsConfiguration.configure(socket, needClientAuth = false)
        socket.soTimeout = timeoutMillis
        socket.startHandshake()
        socket.soTimeout = 0
        SocketFrameTransport(socket, scope)
    }
}
