package id.my.wandidev.klyndro

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import id.my.wandidev.klyndro.crypto.EncryptedTrustStore
import id.my.wandidev.klyndro.crypto.Fingerprint
import id.my.wandidev.klyndro.crypto.KeystoreSecretBox
import id.my.wandidev.klyndro.crypto.TrustedPeer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.security.KeyStore

/**
 * On-device proof for the sealed trust store that pairing writes to.
 *
 * The JVM suite exercises [EncryptedTrustStore] logic against a fake SecretBox, but only this run
 * touches the real `AndroidKeyStore` AES-256-GCM path in [KeystoreSecretBox] — the exact code
 * `PairingRunner.persistAndFinish` depends on when it calls `trustStore.upsert`. It exists to
 * isolate (or exonerate) the trust store as the cause of the on-device pairing `internal` failure
 * recorded in docs/testing/verification-status.md (M2-D1).
 *
 * A dedicated alias and prefs file are used so the test never disturbs real paired-device state.
 */
@RunWith(AndroidJUnit4::class)
class EncryptedTrustStoreInstrumentedTest {

    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    @After
    fun tearDown() {
        prefs.edit().clear().apply()
        runCatching {
            KeyStore.getInstance(PROVIDER).apply { load(null) }.deleteEntry(TEST_ALIAS)
        }
    }

    private fun peer(deviceId: String, name: String, fingerprintHex: String = "a".repeat(64)) =
        TrustedPeer(
            deviceId = deviceId,
            name = name,
            platform = "macos",
            fingerprint = fingerprintHex,
            lastHost = "192.168.1.10",
            lastPort = 47823,
        )

    @Test
    fun sealedRoundTripSurvivesReloadWithTheSameKeystoreKey() {
        val store = EncryptedTrustStore(prefs, KeystoreSecretBox(TEST_ALIAS))
        val original = peer("0123456789abcdef", "Wandi MacBook")

        store.upsert(original)

        val readBack = store.peer(original.deviceId)
        assertNotNull("the peer must be readable from the same store instance", readBack)
        assertEquals(original.name, readBack!!.name)
        assertEquals(original.fingerprint, readBack.fingerprint)
        assertEquals(original.lastPort, readBack.lastPort)

        // A fresh store over the same prefs must unseal with the persisted AndroidKeyStore key.
        // Pairing's post-confirm reconnect depends on this key being stable across loads.
        val reloaded = EncryptedTrustStore(prefs, KeystoreSecretBox(TEST_ALIAS)).allPeers()
        assertEquals(1, reloaded.size)
        assertEquals(original.deviceId, reloaded[0].deviceId)
        val pinned = Fingerprint.parse(original.fingerprint)
        assertNotNull(pinned)
        assertTrue(
            "the reloaded fingerprint must still authorise the peer",
            reloaded[0].authorises(pinned!!),
        )
    }

    @Test
    fun persistedBlobIsSealedNotPlaintext() {
        val store = EncryptedTrustStore(prefs, KeystoreSecretBox(TEST_ALIAS))
        store.upsert(peer("fedcba9876543210", "SuperSecretDeviceName"))

        assertFalse("the trust store must have written something", prefs.all.isEmpty())
        val leaksName = prefs.all.values.any { it is String && it.contains("SuperSecretDeviceName") }
        assertFalse(
            "AGENTS.md forbids plaintext trust state in SharedPreferences; the value must be sealed",
            leaksName,
        )
    }

    @Test
    fun upsertReplacesInPlaceAndRemoveClears() {
        val store = EncryptedTrustStore(prefs, KeystoreSecretBox(TEST_ALIAS))
        val id = "0000000000000001"

        store.upsert(peer(id, "First"))
        store.upsert(peer(id, "Second", fingerprintHex = "b".repeat(64)))
        assertEquals("upsert must replace an existing device id, not duplicate it", 1, store.allPeers().size)
        assertEquals("Second", store.peer(id)?.name)

        store.remove(id)
        assertNull("a removed peer must no longer resolve", store.peer(id))

        store.upsert(peer(id, "Again"))
        store.removeAll()
        assertTrue("removeAll must clear every peer", store.allPeers().isEmpty())
    }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val PREFS_NAME = "klyndro_trust_instrumented_test"
        const val TEST_ALIAS = "id.my.wandidev.klyndro.trust.test"
    }
}
