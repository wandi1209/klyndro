package id.my.wandidev.klyndro.crypto

import id.my.wandidev.klyndro.protocol.isHexDigit
import id.my.wandidev.klyndro.protocol.toHexString
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * A pinned peer identity: lowercase hex SHA-256 of the DER-encoded SubjectPublicKeyInfo.
 *
 * The SPKI (not the whole certificate) is hashed so that re-issuing a certificate for the same
 * key does not invalidate trust. See protocol §5.4.
 */
class Fingerprint private constructor(val hex: String) {

    /** Constant-time comparison, for the confirmation step in protocol §7. */
    fun matches(other: Fingerprint): Boolean = matchesHex(other.hex)

    fun matchesHex(otherHex: String): Boolean {
        val left = hex.toByteArray(Charsets.US_ASCII)
        val right = otherHex.lowercase().toByteArray(Charsets.US_ASCII)
        if (left.size != right.size) return false
        var difference = 0
        for (index in left.indices) {
            difference = difference or (left[index].toInt() xor right[index].toInt())
        }
        return difference == 0
    }

    /** First 8 hex characters, for logs and UI. Never the full value in a log line. */
    val shortHex: String get() = hex.substring(0, 8)

    override fun equals(other: Any?): Boolean = other is Fingerprint && other.hex == hex
    override fun hashCode(): Int = hex.hashCode()
    override fun toString(): String = hex

    companion object {
        const val HEX_LENGTH = 64

        fun parse(value: String): Fingerprint? =
            if (value.length == HEX_LENGTH && value.all { it.isHexDigit() }) {
                Fingerprint(value.lowercase())
            } else {
                null
            }

        fun ofDigest(digest: ByteArray): Fingerprint {
            require(digest.size == 32) { "a SHA-256 digest is 32 bytes" }
            return Fingerprint(digest.toHexString())
        }

        fun ofSpki(spki: ByteArray): Fingerprint =
            ofDigest(MessageDigest.getInstance("SHA-256").digest(spki))
    }
}

/** A per-connection 16-byte random value, hex encoded (protocol §4/§5.1). */
class Nonce private constructor(val hex: String) {

    /** Constant-time comparison, for confirmation values. */
    fun matches(other: Nonce): Boolean {
        val left = hex.toByteArray(Charsets.US_ASCII)
        val right = other.hex.toByteArray(Charsets.US_ASCII)
        if (left.size != right.size) return false
        var difference = 0
        for (index in left.indices) {
            difference = difference or (left[index].toInt() xor right[index].toInt())
        }
        return difference == 0
    }

    override fun equals(other: Any?): Boolean = other is Nonce && other.hex == hex
    override fun hashCode(): Int = hex.hashCode()
    override fun toString(): String = hex

    companion object {
        const val BYTE_COUNT = 16
        const val HEX_LENGTH = 32

        fun parse(value: String): Nonce? =
            if (value.length == HEX_LENGTH && value.all { it.isHexDigit() }) {
                Nonce(value.lowercase())
            } else {
                null
            }

        fun random(random: SecureRandom = SecureRandom()): Nonce {
            val bytes = ByteArray(BYTE_COUNT)
            random.nextBytes(bytes)
            return Nonce(bytes.toHexString())
        }
    }
}

/**
 * The six-digit short authentication string shown on both devices during pairing (§7).
 *
 * Ordering is by fingerprint so both devices hash identical bytes regardless of who initiated.
 */
class PairingCode(val digits: String, val digest: Fingerprint) {

    /** Confirms the peer computed the same digest. Digit equality alone is not enough. */
    fun matchesDigest(hex: String): Boolean = digest.matchesHex(hex)

    companion object {
        fun derive(
            fingerprintA: Fingerprint,
            nonceA: Nonce,
            fingerprintB: Fingerprint,
            nonceB: Nonce
        ): PairingCode {
            val (firstFp, firstNonce, secondFp, secondNonce) =
                if (fingerprintA.hex <= fingerprintB.hex) {
                    listOf(fingerprintA.hex, nonceA.hex, fingerprintB.hex, nonceB.hex)
                } else {
                    listOf(fingerprintB.hex, nonceB.hex, fingerprintA.hex, nonceA.hex)
                }

            val input = "klyndro-sas-v1$firstFp$firstNonce$secondFp$secondNonce"
            val digestBytes = MessageDigest.getInstance("SHA-256")
                .digest(input.toByteArray(Charsets.US_ASCII))

            val value = ((digestBytes[0].toLong() and 0xFF) shl 24) or
                ((digestBytes[1].toLong() and 0xFF) shl 16) or
                ((digestBytes[2].toLong() and 0xFF) shl 8) or
                (digestBytes[3].toLong() and 0xFF)
            val code = value % 1_000_000L

            return PairingCode(
                digits = code.toString().padStart(6, '0'),
                digest = Fingerprint.ofDigest(digestBytes)
            )
        }
    }
}
