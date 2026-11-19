import Foundation
import Testing

@testable import KnitMesh

/// The real clocks behind ``MeshClock``, which the app and knit-peer run on.
@Suite struct SystemClockTests {
    @Test func theSystemClockCountsUpAndSleepsToItsDeadline() async throws {
        let clock = SystemClock()
        let start = clock.monotonicMilliseconds()
        #expect(start >= 1000)
        #expect(abs(clock.wallMilliseconds() - Int64(Date().timeIntervalSince1970 * 1000)) < 1000)
        try await clock.sleep(untilMonotonic: start + 20)
        #expect(clock.monotonicMilliseconds() >= start + 20)
    }

    /// A heal round with no step reports `.min` as its deadline, "due now": the clock wakes at once rather than trapping.
    /// The bound is pinned in its arithmetic, not timed: the whole suite in parallel, under ThreadSanitizer, starved the
    /// task pool for 46 s around these wake-ups, where one alone takes about 1 ms.
    @Test func aDeadlineAtOrBeforeTheOriginIsDueAtOnce() async throws {
        let start = SystemClock().monotonicMilliseconds()
        for deadline in [Int64.min, -1, 0, 999, 1000] {
            #expect(SystemClock.offset(untilMonotonic: deadline) == 0, "\(deadline) is due at the origin")
        }
        #expect(SystemClock.offset(untilMonotonic: 1005) == 5)
        #expect(SystemClock.offset(untilMonotonic: .max) == SystemClock.offset(untilMonotonic: SystemClock.farthest))
        #expect(SystemClock.offset(untilMonotonic: SystemClock.farthest) > 0)
        for deadline in [Int64.min, start - 1] {
            try await SystemClock().sleep(untilMonotonic: deadline)
        }
    }

    /// A deadline saturated at `Int64.max`, "never", sleeps until it is cancelled rather than trapping.
    @Test func aDeadlineAtTheEndOfTheRangeSleepsUntilCancelled() async {
        let clock = SystemClock()
        let sleeper = Task { try await clock.sleep(untilMonotonic: .max) }
        try? await Task.sleep(for: .milliseconds(20))
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
    }
}
