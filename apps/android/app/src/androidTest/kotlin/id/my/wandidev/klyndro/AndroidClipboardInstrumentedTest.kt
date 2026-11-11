package id.my.wandidev.klyndro

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import id.my.wandidev.klyndro.clipboard.AndroidClipboard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Proves the clipboard path on the device's own runtime, which the JVM suite cannot: Android 10+
 * only lets a *focused* app read or write the primary clip, so [MainActivity] is launched to hold
 * focus while the assertions run. This is the instrumented half of the F02 "actual test results"
 * requirement (see docs/architecture/clipboard.md).
 *
 * Launching the Activity is side-effect free here: the clipboard poll loop only starts once a
 * session is CONNECTED, and no service, discovery, or permission prompt is triggered by onCreate.
 */
@RunWith(AndroidJUnit4::class)
class AndroidClipboardInstrumentedTest {

    private fun context(): Context = InstrumentationRegistry.getInstrumentation().targetContext

    /**
     * Window focus can lag the RESUMED callback, and an unfocused clipboard call throws
     * SecurityException on some OEM builds. Retry until the platform accepts the operation so a
     * brief focus delay is not mistaken for a permanent restriction.
     */
    private fun pollUntilAccepted(timeoutMs: Long, operation: () -> Boolean): Boolean {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (SystemClock.uptimeMillis() < deadline) {
            if (runCatching { operation() }.getOrDefault(false)) return true
            SystemClock.sleep(POLL_STEP_MILLIS)
        }
        return runCatching { operation() }.getOrDefault(false)
    }

    @Test
    fun focusedAppCanWriteThenReadThePrimaryClip() {
        ActivityScenario.launch(MainActivity::class.java).use {
            val clipboard = AndroidClipboard(context())
            val text = "Klyndro instrumented ${System.currentTimeMillis()}"

            val written = pollUntilAccepted(FOCUS_TIMEOUT_MILLIS) { clipboard.write(text) }
            assertTrue(
                "a focused app must be allowed to write the clipboard on this device/HyperOS build",
                written,
            )
            assertTrue("a successful write implies clipboard access", clipboard.hasAccess)

            val snapshot = clipboard.read()
            assertNotNull("a focused read must return the clip that was just written", snapshot)
            assertEquals(text, snapshot!!.text)
            assertFalse("plain text written by the test is not sensitive", snapshot.sensitive)
            assertTrue("a real content change must advance the derived counter", snapshot.changeCount > 0)
        }
    }

    @Test
    fun sensitiveClipIsDetectedOnApi33Plus() {
        // The EXTRA_IS_SENSITIVE flag only exists on API 33+; below that there is nothing to read,
        // so the case is skipped rather than failed.
        assumeTrue(
            "sensitive-clip detection requires API 33+",
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU,
        )

        ActivityScenario.launch(MainActivity::class.java).use {
            val manager = context().getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clipboard = AndroidClipboard(context())

            val detected = pollUntilAccepted(FOCUS_TIMEOUT_MILLIS) {
                val clip = ClipData.newPlainText("Klyndro", "hunter2")
                clip.description.extras.putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                manager.setPrimaryClip(clip)
                clipboard.isCurrentClipSensitive()
            }
            assertTrue(
                "a clip flagged EXTRA_IS_SENSITIVE must be detected while focused on API 33+",
                detected,
            )
        }
    }

    private companion object {
        const val FOCUS_TIMEOUT_MILLIS = 5_000L
        const val POLL_STEP_MILLIS = 150L
    }
}
