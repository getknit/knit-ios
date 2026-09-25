import KnitMesh
import Testing

/// The backoff curve, ported from knit-next's `ConnectBackoffPolicyTest`. A draw of 0.5 means no jitter.
@Suite struct ConnectBackoffTests {
    @Test(arguments: [(1, 10_000), (2, 20_000), (3, 40_000), (4, 80_000), (5, 160_000)] as [(Int, Int64)])
    func theWaitDoublesPerFailure(streak: Int, expected: Int64) {
        #expect(ConnectBackoff.delay(afterStreak: streak, random: 0.5) == expected)
    }

    @Test(arguments: [6, 7, 50, Int.max])
    func theWaitStopsAtTheCeiling(streak: Int) {
        #expect(ConnectBackoff.delay(afterStreak: streak, random: 0.5) == 180_000)
    }

    @Test(arguments: [0, -5, Int.min])
    func aStreakBelowOneCountsAsTheFirstFailure(streak: Int) {
        #expect(ConnectBackoff.delay(afterStreak: streak, random: 0.5) == 10_000)
    }

    @Test func jitterSpansTheConfiguredFraction() {
        #expect(ConnectBackoff.delay(afterStreak: 1, random: 0) == 8000)
        #expect(ConnectBackoff.delay(afterStreak: 1, random: 1) == 12_000)
        for draw in [0, 0.1, 0.5, 0.9, 0.999] {
            let delay = ConnectBackoff.delay(afterStreak: 3, random: draw)
            #expect((32_000...48_000).contains(delay), "\(delay) is within 20 % of 40 s")
        }
    }

    @Test func theEngineSleepsToTheEarliestDeadlineWithinItsBounds() {
        #expect(ConnectBackoff.wait(now: 100_000, nextDueAt: nil, minimum: 1000, maximum: 60_000) == 60_000)
        #expect(ConnectBackoff.wait(now: 100_000, nextDueAt: 107_500, minimum: 1000, maximum: 60_000) == 7500)
        #expect(ConnectBackoff.wait(now: 100_000, nextDueAt: 99_000, minimum: 1000, maximum: 60_000) == 1000)
        #expect(ConnectBackoff.wait(now: 100_000, nextDueAt: 400_000, minimum: 1000, maximum: 60_000) == 60_000)
    }
}
