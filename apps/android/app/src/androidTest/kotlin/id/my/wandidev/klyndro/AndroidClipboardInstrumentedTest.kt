package id.my.wandidev.klyndro

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import id.my.wandidev.klyndro.clipboard.AndroidClipboard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Proves the clipboard path on the device runtime while Klyndro is in the foreground.
 *
 * Android 10+ strictly enforces that only the focused window on the UI thread may access
 * `ClipboardManager.primaryClip`. Background test threads are denied with:
 * "Denying clipboard access, application is not in focus nor is it a system service".
 *
 * We launch [MainActivity] and dispatch the clipboard operations directly via [ActivityScenario.onActivity]
 * on the focused Activity's UI thread, matching production usage in [KlyndroViewModel].
 */
@RunWith(AndroidJUnit4::class)
class AndroidClipboardInstrumentedTest {

    @Test
    fun focusedAppCanWriteReadAndDetectSensitiveClip() {
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        try {
            // Wait briefly for the window to gain input focus
            Thread.sleep(1_000)

            val text = "Klyndro instrumented ${System.currentTimeMillis()}"
            val writeSuccess = AtomicBoolean(false)
            val readSnapshot = AtomicReference<id.my.wandidev.klyndro.clipboard.ClipboardSnapshot?>()
            val sensitiveDetected = AtomicBoolean(false)
            val latch = CountDownLatch(1)

            scenario.onActivity { activity ->
                val clipboard = AndroidClipboard(activity)
                val manager = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

                // 1. Write from focused Activity
                val written = clipboard.write(text)
                writeSuccess.set(written && clipboard.hasAccess)

                // 2. Read from focused Activity
                val snapshot = clipboard.read()
                readSnapshot.set(snapshot)

                // 3. Sensitive clip detection (API 33+)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val clip = ClipData.newPlainText("Klyndro", "hunter2").apply {
                        description.extras = android.os.PersistableBundle().apply {
                            putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                        }
                    }
                    manager.setPrimaryClip(clip)
                    val desc = manager.primaryClipDescription
                    sensitiveDetected.set(AndroidClipboard.isSensitive(desc))
                } else {
                    sensitiveDetected.set(true)
                }

                latch.countDown()
            }

            assertTrue("onActivity must finish in 5s", latch.await(5, TimeUnit.SECONDS))
            assertTrue("focused activity write must succeed", writeSuccess.get())

            val snapshot = readSnapshot.get()
            assertNotNull("focused activity read must return snapshot", snapshot)
            assertEquals(text, snapshot!!.text)
            assertFalse("plain text is not sensitive", snapshot.sensitive)
            assertTrue("change counter must advance", snapshot.changeCount > 0)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                assertTrue("EXTRA_IS_SENSITIVE must be detected", sensitiveDetected.get())
            }
        } finally {
            scenario.close()
        }
    }
}
