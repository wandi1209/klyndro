package id.my.wandidev.klyndro.net

import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Bounded exponential backoff with jitter, protocol §2 and F04.
 *
 * The caller supplies the random draw so tests are deterministic.
 */
class ReconnectPolicy(
    private val initialDelaySeconds: Double = 1.0,
    private val maxDelaySeconds: Double = 30.0,
    private val multiplier: Double = 2.0,
    private val jitterFraction: Double = 0.2
) {
    init {
        require(initialDelaySeconds > 0) { "initialDelaySeconds must be positive" }
        require(maxDelaySeconds >= initialDelaySeconds) { "maxDelaySeconds must be at least initialDelaySeconds" }
        require(multiplier >= 1) { "multiplier must be at least 1" }
        require(jitterFraction in 0.0..1.0) { "jitterFraction must be in 0..1" }
    }

    /**
     * Delay before the next attempt.
     *
     * @param attempt zero-based failure count; `0` yields `initialDelaySeconds`.
     * @param jitter uniform draw in `[0, 1]`; pass `0.5` for the un-jittered delay.
     */
    fun delaySeconds(attempt: Int, jitter: Double): Double {
        val exponent = max(0, attempt).toDouble()
        val raw = min(maxDelaySeconds, initialDelaySeconds * multiplier.pow(exponent))
        val clampedJitter = jitter.coerceIn(0.0, 1.0)
        val factor = 1 + (clampedJitter * 2 - 1) * jitterFraction
        return min(maxDelaySeconds, max(0.0, raw * factor))
    }

    fun delaySeconds(attempt: Int): Double = delaySeconds(attempt, Math.random())
}
