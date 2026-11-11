package id.my.wandidev.klyndro.crypto

import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Symmetric sealing for data at rest. Abstracted so storage logic is testable on the JVM. */
interface SecretBox {
    fun seal(plain: ByteArray): ByteArray
    fun open(sealed: ByteArray): ByteArray
}

/**
 * AES-256-GCM with a key that never leaves the Android Keystore.
 *
 * Pairing records contain device identifiers and pinned public fingerprints. They are not secrets
 * in the cryptographic sense, but `AGENTS.md` forbids putting trust state in plain
 * `SharedPreferences`, and encrypting it costs little.
 */
class KeystoreSecretBox(private val alias: String = DEFAULT_ALIAS) : SecretBox {

    override fun seal(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(plain)
        // iv length is prefixed so `open` can reconstruct the exact parameters.
        return byteArrayOf(iv.size.toByte()) + iv + ciphertext
    }

    override fun open(sealed: ByteArray): ByteArray {
        if (sealed.size < 2) throw IllegalArgumentException("sealed payload is too short")
        val ivLength = sealed[0].toInt()
        if (ivLength <= 0 || sealed.size < 1 + ivLength) {
            throw IllegalArgumentException("sealed payload has an invalid iv")
        }
        val iv = sealed.copyOfRange(1, 1 + ivLength)
        val ciphertext = sealed.copyOfRange(1 + ivLength, sealed.size)

        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, iv))
        return cipher.doFinal(ciphertext)
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        generator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val TAG_BITS = 128
        const val DEFAULT_ALIAS = "id.my.wandidev.klyndro.trust"
    }
}

/** Trust store persisted in `SharedPreferences`, sealed with a [SecretBox]. */
class EncryptedTrustStore(
    private val prefs: SharedPreferences,
    private val secretBox: SecretBox
) : TrustStore {

    override fun allPeers(): List<TrustedPeer> {
        val encoded = prefs.getString(KEY, null) ?: return emptyList()
        val json = runCatching {
            secretBox.open(Base64.decode(encoded, Base64.NO_WRAP)).toString(Charsets.UTF_8)
        }.getOrNull() ?: return emptyList()
        // A record we cannot decode means "no paired devices": the user can pair again, and
        // guessing at half-decoded trust data would be worse.
        return TrustStoreCodec.decode(json)
    }

    override fun peer(id: String): TrustedPeer? = allPeers().firstOrNull { it.deviceId == id }

    override fun upsert(peer: TrustedPeer) {
        val peers = allPeers().toMutableList()
        val index = peers.indexOfFirst { it.deviceId == peer.deviceId }
        if (index >= 0) peers[index] = peer else peers.add(peer)
        write(peers)
    }

    override fun remove(id: String) {
        write(allPeers().filterNot { it.deviceId == id })
    }

    override fun removeAll() {
        prefs.edit().remove(KEY).apply()
    }

    private fun write(peers: List<TrustedPeer>) {
        val sealed = secretBox.seal(TrustStoreCodec.encode(peers).toByteArray(Charsets.UTF_8))
        prefs.edit().putString(KEY, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    private companion object {
        const val KEY = "paired_peers_sealed"
    }
}
