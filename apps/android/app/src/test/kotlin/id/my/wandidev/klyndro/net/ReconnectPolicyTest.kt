package id.my.wandidev.klyndro.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReconnectPolicyTest {

    private val policy = ReconnectPolicy(
        initialDelaySeconds = 1.0,
        maxDelaySeconds = 30.0,
        multiplier = 2.0,
        jitterFraction = 0.2
    )

    private fun assertClose(expected: Double, actual: Double) {
        assertEquals(expected, actual, 1e-9)
    }

    @Test
    fun `starts at the initial delay`() {
        assertClose(1.0, policy.delaySeconds(attempt = 0, jitter = 0.5))
    }

    @Test
    fun `doubles per attempt before the cap`() {
        assertClose(2.0, policy.delaySeconds(attempt = 1, jitter = 0.5))
        assertClose(4.0, policy.delaySeconds(attempt = 2, jitter = 0.5))
        assertClose(16.0, policy.delaySeconds(attempt = 4, jitter = 0.5))
    }

    @Test
    fun `never exceeds the maximum delay`() {
        (5..50).forEach { attempt ->
            val delay = policy.delaySeconds(attempt = attempt, jitter = 0.5)
            assertTrue("attempt $attempt produced $delay", delay <= 30.0)
        }
    }

    @Test
    fun `jitter stays inside the configured band`() {
        assertClose(0.8, policy.delaySeconds(attempt = 0, jitter = 0.0))
        assertClose(1.2, policy.delaySeconds(attempt = 0, jitter = 1.0))
        assertClose(3.2, policy.delaySeconds(attempt = 2, jitter = 0.0))
        assertClose(4.8, policy.delaySeconds(attempt = 2, jitter = 1.0))
    }

    @Test
    fun `delay is monotonic in the attempt counter`() {
        var previous = 0.0
        (0..20).forEach { attempt ->
            val delay = policy.delaySeconds(attempt = attempt, jitter = 0.5)
            assertTrue("delay decreased at attempt $attempt", delay >= previous)
            previous = delay
        }
    }

    @Test
    fun `negative attempts are treated as the first attempt`() {
        assertClose(
            policy.delaySeconds(attempt = 0, jitter = 0.5),
            policy.delaySeconds(attempt = -5, jitter = 0.5)
        )
    }

    @Test
    fun `random jitter stays within the band`() {
        repeat(200) {
            val delay = policy.delaySeconds(attempt = 0)
            assertTrue("delay $delay out of band", delay >= 0.8 - 1e-9 && delay <= 1.2 + 1e-9)
        }
    }
}
