package id.my.wandidev.klyndro.crypto

import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.BasicConstraints
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.asn1.x509.KeyUsage
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.math.BigInteger
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.util.Date
import java.util.concurrent.TimeUnit

/**
 * This device's long-term identity: a P-256 key and its self-signed certificate.
 *
 * Certificate encoding is BouncyCastle's; the signature is produced by the JCA `Signature`
 * engine backed by the given private key. No cryptographic primitive is implemented here
 * (ADR 0008).
 */
class DeviceIdentity(
    val privateKey: PrivateKey,
    val certificate: java.security.cert.X509Certificate,
    val commonName: String
) {
    val certificateDer: ByteArray get() = certificate.encoded

    val fingerprint: Fingerprint get() = Fingerprint.ofSpki(certificate.publicKey.encoded)

    companion object {
        const val SUBJECT_PREFIX = "Klyndro "

        /** Generates a fresh P-256 key pair using the platform's EC provider. */
        fun generateKeyPair(random: SecureRandom = SecureRandom()): KeyPair {
            val generator = KeyPairGenerator.getInstance("EC")
            generator.initialize(ECGenParameterSpec("secp256r1"), random)
            return generator.generateKeyPair()
        }

        /** Builds a self-signed certificate around an existing key pair. */
        fun createSelfSigned(
            commonName: String,
            keyPair: KeyPair,
            now: Date = Date(),
            validityDays: Long = 3650,
            random: SecureRandom = SecureRandom()
        ): DeviceIdentity {
            val subject = X500Name("CN=${SUBJECT_PREFIX}$commonName")
            val serial = BigInteger(64, random)
            val notBefore = Date(now.time - TimeUnit.HOURS.toMillis(1))
            val notAfter = Date(now.time + TimeUnit.DAYS.toMillis(validityDays))

            val builder = JcaX509v3CertificateBuilder(
                subject,
                serial,
                notBefore,
                notAfter,
                subject,
                keyPair.public
            )
            // A leaf that is not a CA. Klyndro pins fingerprints instead of building chains.
            builder.addExtension(Extension.basicConstraints, true, BasicConstraints(false))
            builder.addExtension(
                Extension.keyUsage,
                false,
                KeyUsage(KeyUsage.digitalSignature or KeyUsage.keyEncipherment)
            )

            val signer = JcaContentSignerBuilder("SHA256withECDSA").build(keyPair.private)
            val certificate = JcaX509CertificateConverter().getCertificate(builder.build(signer))
            certificate.verify(keyPair.public)

            return DeviceIdentity(
                privateKey = keyPair.private,
                certificate = certificate,
                commonName = commonName
            )
        }
    }
}

/**
 * Generates the device identity, persisting the key in the Android Keystore.
 *
 * Not exercised by the JVM test suite: `AndroidKeyStore` needs a device. The JVM tests cover
 * `createSelfSigned` and everything downstream of it, which is where the protocol logic lives.
 */
object AndroidKeyStoreIdentities {
    private const val ALIAS = "id.my.wandidev.klyndro.identity"

    fun loadOrCreate(commonName: String): DeviceIdentity {
        val keyStore = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keyStore.containsAlias(ALIAS)) {
            val key = keyStore.getKey(ALIAS, null) as? PrivateKey
            val certificate = keyStore.getCertificate(ALIAS) as? java.security.cert.X509Certificate
            if (key != null && certificate != null) {
                return DeviceIdentity(key, certificate, commonName)
            }
            keyStore.deleteEntry(ALIAS)
        }

        val keyPair = DeviceIdentity.generateKeyPair()
        val identity = DeviceIdentity.createSelfSigned(commonName, keyPair)
        // The generated pair is imported as the Keystore entry so later sessions can sign with
        // it. A future revision can use a non-exportable Keystore key directly; that requires
        // an attestation-free certificate bootstrap and is tracked in ADR 0008.
        keyStore.setKeyEntry(ALIAS, keyPair.private, null, arrayOf(identity.certificate))
        return identity
    }

    fun delete() {
        val keyStore = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keyStore.containsAlias(ALIAS)) keyStore.deleteEntry(ALIAS)
    }
}
