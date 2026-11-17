import Testing

@testable import KnitMesh

/// The redial curve: knit-next's `SpoolBackoffPolicyTest` at `0832b8462`, case for case, then the jitter and the
/// `Retry-After` floor `ScopeSync.Worker.runLoop` puts on it (`:1471-1481`). That suite has no case left to another plane.
@Suite struct SpoolBackoffTests {
    @Test func aReachedSessionReconnectsAfterASecond() {
        #expect(SpoolBackoff.waitMilliseconds(failures: 0) == 1000)
        #expect(SpoolBackoff.waitMilliseconds(failures: -3) == 1000)
    }

    @Test func theFirstTierDoublesToAMinute() {
        #expect(SpoolBackoff.waitMilliseconds(failures: 1) == 2000)
        #expect(SpoolBackoff.waitMilliseconds(failures: 2) == 4000)
        #expect(SpoolBackoff.waitMilliseconds(failures: 3) == 8000)
        #expect(SpoolBackoff.waitMilliseconds(failures: 5) == 32_000)
        #expect(SpoolBackoff.waitMilliseconds(failures: 6) == 60_000)
        #expect(SpoolBackoff.waitMilliseconds(failures: SpoolBackoff.longTierAfter) == 60_000)
    }

    @Test func theLongTierDoublesOnToFifteenMinutes() {
        let after = SpoolBackoff.longTierAfter
        #expect(SpoolBackoff.waitMilliseconds(failures: after + 1) == 120_000)
        #expect(SpoolBackoff.waitMilliseconds(failures: after + 2) == 240_000)
        #expect(SpoolBackoff.waitMilliseconds(failures: after + 3) == 480_000)
        #expect(SpoolBackoff.waitMilliseconds(failures: after + 4) == 900_000)
        #expect(SpoolBackoff.waitMilliseconds(failures: after + 5) == 900_000)
    }

    @Test func aHugeStreakDoesNotOverflow() {
        #expect(SpoolBackoff.waitMilliseconds(failures: 100) == 900_000)
        #expect(SpoolBackoff.waitMilliseconds(failures: .max) == 900_000)
        #expect(SpoolBackoff.waitMilliseconds(failures: .min) == 1000)
    }

    @Test func theJitterRidesOnTopAndStaysUnder750() {
        var low = FixedDraw(value: 1)
        var high = FixedDraw(value: .max)
        #expect(SpoolBackoff.delay(failures: 2, retryAfterMilliseconds: nil, using: &low) == 4000)
        let jittered = SpoolBackoff.delay(failures: 2, retryAfterMilliseconds: nil, using: &high)
        #expect((4000..<4750).contains(jittered))
    }

    @Test func aRetryAfterIsAFloorCappedAtAMinuteNeverAReplacement() {
        var draw = FixedDraw(value: 1)
        #expect(SpoolBackoff.delay(failures: 1, retryAfterMilliseconds: 30_000, using: &draw) == 30_000)
        #expect(SpoolBackoff.delay(failures: 12, retryAfterMilliseconds: 30_000, using: &draw) == 240_000, "the curve wins")
        #expect(SpoolBackoff.delay(failures: 0, retryAfterMilliseconds: .max, using: &draw) == 60_000)
        #expect(SpoolBackoff.delay(failures: 0, retryAfterMilliseconds: -5, using: &draw) == 1000)
    }
}

/// A generator that answers one value every time. Not 0: `next(upperBound:)` would draw again for ever.
private struct FixedDraw: RandomNumberGenerator {
    let value: UInt64

    mutating func next() -> UInt64 {
        value
    }
}
