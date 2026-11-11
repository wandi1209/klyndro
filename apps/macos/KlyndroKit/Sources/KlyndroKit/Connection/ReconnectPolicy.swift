import Foundation

/// Bounded exponential backoff with jitter, Klyndro Protocol v1 §2 and F04.
///
/// Pure and deterministic: the caller supplies the random draw so tests never flake.
public struct ReconnectPolicy: Sendable, Equatable {
    public var initialDelay: Double
    public var maxDelay: Double
    public var multiplier: Double
    /// Fraction of the delay that may be added or removed, e.g. `0.2` is ±20 %.
    public var jitterFraction: Double

    public init(
        initialDelay: Double = 1.0,
        maxDelay: Double = 30.0,
        multiplier: Double = 2.0,
        jitterFraction: Double = 0.2
    ) {
        precondition(initialDelay > 0, "initialDelay must be positive")
        precondition(maxDelay >= initialDelay, "maxDelay must be at least initialDelay")
        precondition(multiplier >= 1, "multiplier must be at least 1")
        precondition((0...1).contains(jitterFraction), "jitterFraction must be in 0...1")
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.jitterFraction = jitterFraction
    }

    /// Delay before the next attempt.
    ///
    /// - Parameters:
    ///   - attempt: Zero-based failure count. `0` yields `initialDelay`.
    ///   - jitter: Uniform draw in `[0, 1)`. Pass `0.5` for the un-jittered delay.
    public func delay(forAttempt attempt: Int, jitter: Double) -> Double {
        let exponent = Double(max(0, attempt))
        let raw = min(maxDelay, initialDelay * pow(multiplier, exponent))
        let clampedJitter = min(max(jitter, 0), 1)
        let factor = 1 + (clampedJitter * 2 - 1) * jitterFraction
        return max(0, min(maxDelay, raw * factor))
    }

    /// Convenience for callers without a deterministic draw.
    public func delay(forAttempt attempt: Int) -> Double {
        delay(forAttempt: attempt, jitter: Double.random(in: 0..<1))
    }
}
