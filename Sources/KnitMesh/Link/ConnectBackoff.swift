/// How long to wait before dialing a peer again after repeated failures (`ConnectBackoffPolicy.kt`): double
/// the wait each time from a base, up to a ceiling, spread by jitter so many phones do not retry one peer in
/// lockstep. A link coming up resets the streak.
public enum ConnectBackoff {
    /// The curve's tunables (`BackoffConfig`).
    public struct Configuration: Sendable {
        /// The wait after the first failure.
        public var baseMilliseconds: Int64
        /// The ceiling the doubling stops at.
        public var maxMilliseconds: Int64
        /// The spread applied to each wait, as a fraction of it either way.
        public var jitterFraction: Double

        /// knit-next's values unless told otherwise: 10 s, 180 s and ±20 %.
        public init(baseMilliseconds: Int64 = 10_000, maxMilliseconds: Int64 = 180_000, jitterFraction: Double = 0.2) {
            self.baseMilliseconds = baseMilliseconds
            self.maxMilliseconds = maxMilliseconds
            self.jitterFraction = jitterFraction
        }
    }

    /// Doubling past this many steps already dwarfs any sane ceiling, and bounding it keeps the shift in range.
    private static let maxShift: Int64 = 16

    /// The wait after the `streak`-th failure in a row (1 is the first). `random` is a draw from `0..<1`; 0.5
    /// gives the wait without jitter.
    public static func delay(afterStreak streak: Int, random: Double, configuration: Configuration = Configuration()) -> Int64 {
        let shift = min(Int64(max(streak, 1) - 1), maxShift)
        let raw = min(configuration.baseMilliseconds << shift, configuration.maxMilliseconds)
        let spread = Double(raw) * configuration.jitterFraction
        let jittered = Double(raw) - spread + random * (spread + spread)
        return max(0, Int64(jittered))
    }

    /// How long the connection engine may sleep: until the earliest backoff deadline still ahead, clamped to
    /// `minimum...maximum`, or `maximum` when nothing is due, since any event wakes it sooner.
    public static func wait(now: Int64, nextDueAt: Int64?, minimum: Int64, maximum: Int64) -> Int64 {
        guard let nextDueAt else {
            return maximum
        }
        return min(max(nextDueAt - now, minimum), maximum)
    }
}
