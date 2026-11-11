import KlyndroKit
import Testing

@Suite("Reconnect policy")
struct ReconnectPolicyTests {
    private let policy = ReconnectPolicy(
        initialDelay: 1,
        maxDelay: 30,
        multiplier: 2,
        jitterFraction: 0.2
    )

    @Test("starts at the initial delay")
    func initialDelay() {
        #expect(abs(policy.delay(forAttempt: 0, jitter: 0.5) - 1.0) < 1e-9)
    }

    @Test("doubles per attempt before the cap")
    func exponentialGrowth() {
        #expect(abs(policy.delay(forAttempt: 1, jitter: 0.5) - 2.0) < 1e-9)
        #expect(abs(policy.delay(forAttempt: 2, jitter: 0.5) - 4.0) < 1e-9)
        #expect(abs(policy.delay(forAttempt: 4, jitter: 0.5) - 16.0) < 1e-9)
    }

    @Test("never exceeds the maximum delay")
    func boundedAbove() {
        for attempt in 5...50 {
            let delay = policy.delay(forAttempt: attempt, jitter: 0.5)
            #expect(delay <= 30.0, "attempt \(attempt) produced \(delay)")
        }
    }

    @Test("jitter stays inside the configured band")
    func jitterBand() {
        #expect(abs(policy.delay(forAttempt: 0, jitter: 0) - 0.8) < 1e-9)
        #expect(abs(policy.delay(forAttempt: 0, jitter: 1) - 1.2) < 1e-9)
        #expect(abs(policy.delay(forAttempt: 2, jitter: 0) - 3.2) < 1e-9)
        #expect(abs(policy.delay(forAttempt: 2, jitter: 1) - 4.8) < 1e-9)
    }

    @Test("delay is monotonic in the attempt counter")
    func monotonicInAttempt() {
        var previous = 0.0
        for attempt in 0...20 {
            let delay = policy.delay(forAttempt: attempt, jitter: 0.5)
            #expect(delay >= previous)
            previous = delay
        }
    }

    @Test("negative attempts are treated as the first attempt")
    func negativeAttempt() {
        #expect(policy.delay(forAttempt: -5, jitter: 0.5) == policy.delay(forAttempt: 0, jitter: 0.5))
    }

    @Test("random jitter stays within the band")
    func randomJitterIsBounded() {
        for _ in 0..<200 {
            let delay = policy.delay(forAttempt: 0)
            #expect(delay >= 0.8 - 1e-9)
            #expect(delay <= 1.2 + 1e-9)
        }
    }
}
