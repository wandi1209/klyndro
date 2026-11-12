package id.my.wandidev.klyndro.connection

import id.my.wandidev.klyndro.protocol.PairingFailure
import kotlinx.coroutines.CancellationException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/**
 * Translates low-level socket, TLS, and protocol failures into plain user-facing messages.
 * Technical stack traces and IP/port details stay in logcat only.
 */
object UserErrorFormatter {

    fun formatPairingFailure(reason: PairingFailure): String = when (reason) {
        PairingFailure.USER_REJECTED -> "Pairing was cancelled."
        PairingFailure.SAS_MISMATCH -> "The six-digit codes did not match. Try pairing again."
        PairingFailure.WINDOW_CLOSED -> "Pairing window closed on your Mac. Open Pair Device on your Mac and try again."
        PairingFailure.RATE_LIMITED -> "Too many pairing attempts. Wait a minute and try again."
        PairingFailure.ALREADY_PAIRED -> "This phone is already paired with that Mac."
        PairingFailure.INTERNAL -> "Pairing could not finish. Make sure Klyndro is open on your Mac and try again."
    }

    fun formatConnectionError(error: Throwable): String? {
        if (error is CancellationException) return null
        val message = error.message?.lowercase().orEmpty()

        return when {
            error is SocketTimeoutException || "timed out" in message ->
                "Connection timed out. Make sure your Mac is awake and on the same Wi-Fi."

            error is ConnectException || "econnrefused" in message || "connection refused" in message ->
                "Could not reach your Mac. Make sure Klyndro is open on your Mac."

            error is NoRouteToHostException || error is UnknownHostException ||
                "enetunreach" in message || "no route" in message ->
                "Mac is unreachable on this network. Check that both devices share the same Wi-Fi."

            error is SSLException || "certificate" in message || "trust" in message ->
                "Your Mac did not recognise this phone. Try pairing again."

            else ->
                "Could not connect to your Mac. Please try again."
        }
    }
}
