package id.my.wandidev.klyndro

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import id.my.wandidev.klyndro.crypto.AndroidKeyStoreIdentities
import id.my.wandidev.klyndro.discovery.NsdDiscovery
import id.my.wandidev.klyndro.protocol.Capability
import id.my.wandidev.klyndro.protocol.DeviceId
import id.my.wandidev.klyndro.protocol.Platform
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Android-side mDNS: publish this device and browse for peers.
 *
 * This is the only way to know whether HyperOS lets NSD behave, which cannot be answered on the
 * JVM. The companion check is external: while this test holds the advertisement open, macOS must
 * see it in `dns-sd -B _klyndro._tcp`.
 */
@RunWith(AndroidJUnit4::class)
class DiscoveryInstrumentedTest {

    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val discovery = NsdDiscovery(context)

    @After
    fun tearDown() {
        discovery.stopBrowsing()
        discovery.stopPublishing()
        runCatching { AndroidKeyStoreIdentities.delete() }
    }

    @Test
    fun publishesAndBrowsesWithoutError() {
        val identity = AndroidKeyStoreIdentities.loadOrCreate("Klyndro Discovery Test")

        discovery.publish(
            deviceId = DeviceId.random(),
            name = "Klyndro Android Test",
            fingerprint = identity.fingerprint,
            port = NsdDiscovery.DEFAULT_PORT
        )

        val found = CopyOnWriteArrayList<NsdDiscovery.DiscoveredPeer>()
        val errors = CopyOnWriteArrayList<String>()
        val browseErrors = CountDownLatch(1)

        discovery.browse(
            onPeer = { found.add(it) },
            onError = {
                errors.add(it)
                browseErrors.countDown()
            }
        )

        // Browsing must start without an error. Finding our own advertisement is a bonus: some
        // stacks suppress self-discovery, so absence is not a failure here.
        val browseStarted = browseErrors.await(8, TimeUnit.SECONDS)
        assertTrue(
            "browsing reported an error: ${errors.joinToString()}",
            !browseStarted || errors.isEmpty()
        )

        // Hold the advertisement long enough for an external observer (macOS `dns-sd`) to see it.
        // 45 s leaves room for the test APK install plus a slow first browse.
        Thread.sleep(45_000)

        // Any peer that *is* discovered must be well-formed.
        found.forEach { peer ->
            assertTrue(peer.name.isNotBlank())
            assertTrue(peer.fingerprint.hex.length == 64)
            assertTrue(peer.port == NsdDiscovery.DEFAULT_PORT)
        }
    }

    @Test
    fun publishedServiceTypeMatchesTheProtocolSpecification() {
        // Guards against a typo that would make the Mac invisible to the phone.
        assertTrue(NsdDiscovery.SERVICE_TYPE == "_klyndro._tcp.")
        assertTrue(NsdDiscovery.DEFAULT_PORT == 47_823)
        assertTrue(Platform.ANDROID.wireName == "android")
        assertTrue(Capability.CLIPBOARD.wireName == "clipboard")
    }
}
