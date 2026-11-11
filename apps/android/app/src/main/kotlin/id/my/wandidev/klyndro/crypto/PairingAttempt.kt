package id.my.wandidev.klyndro.crypto

import id.my.wandidev.klyndro.protocol.PairConfirmBody
import id.my.wandidev.klyndro.protocol.PairRequestBody

/**
 * A timed pairing window (protocol §7).
 *
 * The window is the only period during which an unpinned peer may complete a handshake, so its
 * bounds are security-relevant and therefore unit-tested.
 */
class PairingWindow(
    private val openedAtMillis: Long = System.currentTimeMillis(),
    private val durationMillis: Long = DEFAULT_DURATION_MILLIS,
    private val maxAttempts: Int = DEFAULT_MAX_ATTEMPTS
) {
    var attempts: Int = 0
        private set

    fun isOpen(nowMillis: Long = System.currentTimeMillis()): Boolean {
        val elapsed = nowMillis - openedAtMillis
        return elapsed >= 0 && elapsed < durationMillis
    }

    fun remainingMillis(nowMillis: Long = System.currentTimeMillis()): Long =
        (durationMillis - (nowMillis - openedAtMillis)).coerceAtLeast(0)

    /** Counts an attempt or refuses it, before any TLS work is accepted. */
    fun beginAttempt(nowMillis: Long = System.currentTimeMillis()) {
        if (!isOpen(nowMillis)) throw PairingWindowException.WindowClosed
        if (attempts >= maxAttempts) throw PairingWindowException.RateLimited
        attempts += 1
    }

    companion object {
        const val DEFAULT_DURATION_MILLIS = 60_000L
        const val DEFAULT_MAX_ATTEMPTS = 3
    }
}

sealed class PairingWindowException(message: String) : Exception(message) {
    object WindowClosed : PairingWindowException("the pairing window is closed")
    object RateLimited : PairingWindowException("too many pairing attempts")
}

/** One in-flight pairing attempt: enough state to display a code and verify a confirmation. */
class PairingAttempt(
    val remote: PairRequestBody,
    val localFingerprint: Fingerprint,
    val localNonce: Nonce
) {
    /** The six digits both users must see. */
    val code: PairingCode = PairingCode.derive(
        localFingerprint, localNonce, remote.fingerprint, remote.nonce
    )

    fun confirmBody(): PairConfirmBody = PairConfirmBody(
        fingerprint = localFingerprint,
        nonce = localNonce,
        sasDigest = code.digest
    )

    /**
     * Verifies the peer's confirmation. Fingerprint and nonce first: a peer echoing different
     * values cannot have hashed the same input, regardless of the digits.
     */
    fun validate(confirm: PairConfirmBody) {
        if (!confirm.fingerprint.matches(remote.fingerprint)) {
            throw PairingValidationException.FingerprintMismatch
        }
        if (!confirm.nonce.matches(remote.nonce)) {
            throw PairingValidationException.NonceMismatch
        }
        if (!confirm.sasDigest.matches(code.digest)) {
            throw PairingValidationException.DigestMismatch
        }
    }

    fun trustedPeer(host: String?, port: Int?, atMillis: Long = System.currentTimeMillis()) =
        TrustedPeer(
            deviceId = remote.deviceId.hex,
            name = remote.deviceName,
            platform = remote.platform.wireName,
            fingerprint = remote.fingerprint.hex,
            lastHost = host,
            lastPort = port,
            pairedAtMillis = atMillis
        )
}

sealed class PairingValidationException(message: String) : Exception(message) {
    object FingerprintMismatch : PairingValidationException("peer confirmed a different fingerprint")
    object NonceMismatch : PairingValidationException("peer confirmed a different nonce")
    object DigestMismatch : PairingValidationException("peer computed a different pairing code")
}
