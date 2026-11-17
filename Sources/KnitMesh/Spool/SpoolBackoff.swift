/// How long a relay's worker waits before it dials again, by how many sessions in a row ended unreached
/// (`SpoolBackoffPolicy.kt` in knit-next at `0832b8462`, and the wait `ScopeSync.Worker.runLoop` builds on it, `:1455-1487`).
///
/// Two tiers: a second doubling to a minute, the curve C-7.1-11's clients have always run, then for a relay that is simply
/// gone, after ``longTierAfter`` failures, doubling on from a minute to 15. A spool's `Retry-After` (a full spool's 503,
/// S-7.1-10) is a floor under the curve, never in its place, so a long refusal never gets cheaper, and the jitter stays on
/// top of both, so the clients one full spool turned away together do not come back together (C-7.1-11). A reached
/// session, or a new network, starts the count over; that is the caller's.
internal enum SpoolBackoff {
    /// The wait after a reached session, and the first tier's base (`MIN_BACKOFF_MS`).
    static let minimumMilliseconds: Int64 = 1000
    /// The first tier's ceiling (`MAX_BACKOFF_MS`).
    static let firstTierCeilingMilliseconds: Int64 = 60_000
    /// The long tier's ceiling (`LONG_BACKOFF_MS`).
    static let longTierCeilingMilliseconds: Int64 = 900_000
    /// Failures in a row before the long tier (`LONG_TIER_AFTER`).
    static let longTierAfter = 10
    /// The jitter's bound, a draw in 0 up to this, exclusive (`RECONNECT_JITTER_MS`, `Random.nextLong(750)`).
    static let jitterMilliseconds: Int64 = 750
    /// The most a `Retry-After` is honoured for (`MAX_RETRY_AFTER_S`): the first tier's ceiling.
    static let maxRetryAfterMilliseconds: Int64 = 60_000
    /// A shift past this already dwarfs both ceilings; bounding it keeps the value in range on any streak (`MAX_SHIFT`).
    private static let maxShift = 16

    /// The curve alone (`waitMs`): after `failures` unreached sessions in a row, 0 or fewer being the redial after a
    /// reached one.
    static func waitMilliseconds(failures: Int) -> Int64 {
        if failures <= 0 {
            return minimumMilliseconds
        }
        if failures <= longTierAfter {
            return min(minimumMilliseconds << min(failures, maxShift), firstTierCeilingMilliseconds)
        }
        return min(firstTierCeilingMilliseconds << min(failures - longTierAfter, maxShift), longTierCeilingMilliseconds)
    }

    /// The whole wait: the curve, raised to `retryAfterMilliseconds` when the last dial carried one, plus a jitter drawn
    /// from `generator`. The floor is held to 0…60 s here as well as at the parse, since it feeds a timer.
    static func delay(failures: Int, retryAfterMilliseconds: Int64?, using generator: inout some RandomNumberGenerator) -> Int64 {
        let floor = min(max(retryAfterMilliseconds ?? 0, 0), maxRetryAfterMilliseconds)
        let jitter = Int64(generator.next(upperBound: UInt64(jitterMilliseconds)))
        return max(waitMilliseconds(failures: failures), floor) + jitter
    }
}
