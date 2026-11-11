package id.my.wandidev.klyndro.net

import id.my.wandidev.klyndro.crypto.Fingerprint
import id.my.wandidev.klyndro.crypto.TrustedPeer
import java.io.ByteArrayInputStream
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate

/**
 * Decides whether a peer certificate may be trusted.
 *
 * A pure function of the presented certificate and the current policy, so the accept/reject
 * matrix is testable without a socket. Mirrors the Swift `PinPolicy`.
 */
class PinPolicy private constructor(private val mode: Mode) {

    sealed interface Mode {
        /** Only these fingerprints are accepted. Used for every normal session. */
        data class Pinned(val allowed: Set<Fingerprint>) : Mode

        /** Accept any certificate. Only while a pairing window is open. */
        data object PairingWindow : Mode
    }

    fun evaluate(certificateDer: ByteArray): PinDecision {
        val fingerprint = try {
            fingerprintOf(certificateDer)
        } catch (_: Exception) {
            return PinDecision.Rejected(PinRejection.UnparsableCertificate)
        }

        return when (val current = mode) {
            is Mode.PairingWindow -> PinDecision.Accepted(fingerprint, isPinned = false)
            is Mode.Pinned -> when {
                current.allowed.isEmpty() -> PinDecision.Rejected(PinRejection.NoPairedPeers)
                fingerprint in current.allowed -> PinDecision.Accepted(fingerprint, isPinned = true)
                else -> PinDecision.Rejected(PinRejection.FingerprintNotTrusted(fingerprint.shortHex))
            }
        }
    }

    companion object {
        val PAIRING_ONLY: PinPolicy = PinPolicy(Mode.PairingWindow)

        fun pinned(fingerprints: Set<Fingerprint>): PinPolicy = PinPolicy(Mode.Pinned(fingerprints))

        fun pinned(peers: List<TrustedPeer>): PinPolicy =
            PinPolicy(Mode.Pinned(peers.mapNotNull { it.fingerprintValue }.toSet()))

        /** SHA-256 over the DER SubjectPublicKeyInfo, matching the macOS implementation. */
        fun fingerprintOf(certificateDer: ByteArray): Fingerprint {
            val certificate = CertificateFactory.getInstance("X.509")
                .generateCertificate(ByteArrayInputStream(certificateDer)) as X509Certificate
            return Fingerprint.ofSpki(certificate.publicKey.encoded)
        }

        fun fingerprintOf(certificate: X509Certificate): Fingerprint =
            Fingerprint.ofSpki(certificate.publicKey.encoded)
    }
}

sealed interface PinDecision {
    data class Accepted(val fingerprint: Fingerprint, val isPinned: Boolean) : PinDecision
    data class Rejected(val reason: PinRejection) : PinDecision

    val isAccepted: Boolean get() = this is Accepted
}

sealed interface PinRejection {
    data object UnparsableCertificate : PinRejection
    data object NoPairedPeers : PinRejection
    data class FingerprintNotTrusted(val fingerprintPrefix: String) : PinRejection
}
