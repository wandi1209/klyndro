package id.my.wandidev.klyndro

import androidx.test.ext.junit.runners.AndroidJUnit4
import id.my.wandidev.klyndro.crypto.AndroidKeyStoreIdentities
import id.my.wandidev.klyndro.crypto.DeviceIdentity
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * On-device identity checks. These cannot run on the JVM: `AndroidKeyStore` only exists on a
 * device, and the whole point is to prove the Keystore path actually works there.
 */
@RunWith(AndroidJUnit4::class)
class DeviceIdentityInstrumentedTest {

    @After
    fun cleanUp() {
        AndroidKeyStoreIdentities.delete()
    }

    @Test
    fun keystoreIdentityIsCreatedAndReloadsWithTheSameFingerprint() {
        val first = AndroidKeyStoreIdentities.loadOrCreate("Klyndro Test Device")
        val second = AndroidKeyStoreIdentities.loadOrCreate("Klyndro Test Device")

        assertEquals(
            "the persisted identity must keep its pinned fingerprint across loads",
            first.fingerprint.hex,
            second.fingerprint.hex
        )
        assertEquals(64, first.fingerprint.hex.length)
        assertTrue(first.certificateDer.isNotEmpty())
        assertEquals(first.certificateDer.toList(), second.certificateDer.toList())
    }

    @Test
    fun deletingTheIdentityLeavesNoAlias() {
        val first = AndroidKeyStoreIdentities.loadOrCreate("Klyndro Test Device")
        AndroidKeyStoreIdentities.delete()

        val second = AndroidKeyStoreIdentities.loadOrCreate("Klyndro Test Device")
        assertFalse(
            "a deleted identity must not be silently reused",
            first.fingerprint.matches(second.fingerprint)
        )
    }

    @Test
    fun generatedCertificateIsSelfSignedAndValid() {
        val identity = DeviceIdentity.createSelfSigned(
            "Klyndro Certificate Test",
            DeviceIdentity.generateKeyPair()
        )
        identity.certificate.verify(identity.certificate.publicKey)
        assertEquals(identity.certificate.subjectX500Principal, identity.certificate.issuerX500Principal)
        assertTrue(
            "certificate must still be valid",
            identity.certificate.notAfter.after(java.util.Date())
        )
    }
}
