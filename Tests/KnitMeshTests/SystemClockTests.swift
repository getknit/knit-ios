import Foundation
import KnitMesh
import Testing

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
}
