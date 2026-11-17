/// What one relay's pulls may cost in an hour, and when a relay's serves are faulted (P3b; this port's own rules).
///
/// Two bounds, both per relay over an hour on the monotonic clock, and neither starts over for anything but the hour:
/// - **bytes.** A pull is sent only while its worst case, every id it names at ``ScopeFrames/maxBlob`` (the bound the
///   session enforces on a pulled blob), fits what the hour has left. The worst case is charged when the pull goes; an
///   arrival past it is charged at once; what the blobs did not use is given back when the pull ends. A blob served past
///   ``ScopeFrames/maxBlob`` is charged for every byte it carried. So a relay's pulls in an hour cost at most
///   ``maxPulledBytes``, one pull's worst case, and the bytes of the blobs that pull's ids were served past the bound.
///   Nothing is lost: a spool keeps a blob 48 h, and a pull the hour cannot carry waits for the next.
/// - **faults.** A blob whose bytes do not hash to the id it was served under, and a blob served past
///   ``ScopeFrames/maxBlob``, count against the relay. Once ``faultAfterFailures`` of those came in the hour, and more
///   than blobs that hashed true, the relay is faulted (``SpoolFault/unopenable``) and its backoff grows. A blob that
///   hashes true and then fails to open, decode, fit the rule or verify could have been pushed by anyone who knows the
///   scope, or minted by the spool; it cannot be pinned on the relay, so it is quarantined, and the byte budget is what
///   bounds a relay that serves such blobs. A live `event` never counts.
internal struct SpoolIntake: Sendable, Equatable {
    /// The window, an hour.
    static let windowMilliseconds: Int64 = 3_600_000
    /// The pulled bytes one relay may cost in a window.
    static let maxPulledBytes = 16 << 20
    /// The failures in a window before the ratio is read at all.
    static let faultAfterFailures = 32

    private var windowStart: Int64?
    /// Bytes charged in the current window.
    private(set) var bytes = 0
    /// Pulled blobs that hashed to their id in the current window.
    private(set) var opened = 0
    /// Spool-caused failures in the current window.
    private(set) var failed = 0

    /// The bytes the hour has left at `now`.
    mutating func room(now: Int64) -> Int {
        roll(now)
        return max(Self.maxPulledBytes - bytes, 0)
    }

    /// Charges `count` bytes: a pull's worst case when it goes, or what an oversize blob carried.
    mutating func charge(bytes count: Int, now: Int64) {
        roll(now)
        bytes = bytes > Int.max - max(count, 0) ? Int.max : bytes + max(count, 0)
    }

    /// Gives back what a pull's worst case did not use. An hour that has since ended starts at nothing at its next read
    /// anyway, so no clock is needed.
    mutating func refund(bytes count: Int) {
        bytes -= min(max(count, 0), bytes)
    }

    /// A pulled blob was judged: `spoolFault` when the spool alone could have caused what went wrong. Answers whether the
    /// relay is now faulted, which starts the failure count over and leaves the hour's bytes as they are.
    mutating func judged(spoolFault fault: Bool, now: Int64) -> Bool {
        roll(now)
        guard fault else {
            opened += 1
            return false
        }
        failed += 1
        guard failed >= Self.faultAfterFailures, failed > opened else {
            return false
        }
        failed = 0
        opened = 0
        return true
    }

    private mutating func roll(_ now: Int64) {
        if let start = windowStart, now >= start {
            let (elapsed, overflow) = now.subtractingReportingOverflow(start)
            if !overflow, elapsed < Self.windowMilliseconds {
                return
            }
        }
        windowStart = now
        bytes = 0
        opened = 0
        failed = 0
    }
}
