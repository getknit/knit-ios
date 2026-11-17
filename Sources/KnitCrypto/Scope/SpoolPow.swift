import Crypto

/// A spool's proof of work (`SpoolPow`, knit-next `mesh/crypto/scope/SpoolPow.kt` at `0832b8462`; `docs/SPOOL_PROTOCOL.md`
/// §8; ADR 2026-11.adrq): a stamp `n` whose `SHA-256("knit/spool/v1/pow" ‖ scopeId ‖ u64be(day) ‖ u64be(n))` has at
/// least `bits` leading zero bits, for the UTC day on our clock. A spool takes a stamp for its yesterday, today or
/// tomorrow (S-8-1) and asks for one only for a scope it does not hold, so a client mines about once per new scope per
/// day, and only after an `err pow` (C-8-4).
///
/// Mining is plain CPU work, about a million hashes at the usual 20 bits, so the caller runs
/// ``mine(scopeId:day:bits:from:shouldStop:)`` off the `Mesh` actor, and may stop it and resume it later from the counter
/// it reached.
public enum SpoolPow {
    /// What one search answered, each with `tried`, the counters that call hashed: ``found(_:tried:)`` with the stamp,
    /// ``exhausted(tried:)`` when its range ran out, or ``cancelled(tried:)`` when its caller stopped it. A stopped search
    /// resumes at `from + tried` (with `from` at least 0) and answers what one uninterrupted search would.
    public enum Search: Equatable, Sendable {
        /// The smallest counter in the range that meets the bits; `tried` counts it.
        case found(Int64, tried: Int64)
        /// No counter in the range meets the bits, or the bits are out of bounds or the range empty (`tried` 0).
        case exhausted(tried: Int64)
        /// The caller's stop was seen at counter `max(from, 0) + tried`, which was not hashed.
        case cancelled(tried: Int64)

        /// The stamp a search found, or `nil` when it found none.
        public var counter: Int64? {
            guard case .found(let counter, _) = self else {
                return nil
            }
            return counter
        }

        /// The counters this call hashed, which a caller charges to its budget.
        public var tried: Int64 {
            switch self {
            case .found(_, let tried), .exhausted(let tried), .cancelled(let tried):
                tried
            }
        }
    }

    /// One UTC day in milliseconds (`DAY_MS`, `:12`).
    public static let dayMilliseconds: Int64 = 86_400_000
    /// The most difficulty this client mines (`MAX_BITS`, `:24`). `powBits` is the spool's own claim in its HELLO, and
    /// each bit doubles the work, so past 24 bits, 16 times the recommended 20, the answer is to refuse.
    public static let maxBits = 24
    /// The most counters one stamp tries, 2^26, four times a 24-bit stamp's expected cost: the budget Kotlin's caller
    /// passes `stamp` (`POW_BUDGET`, `ScopeSync.kt:3469`).
    public static let maxTries: Int64 = 1 << 26
    /// How many counters run between looks at the caller's stop, counted from where the search starts. A search outlives
    /// the connection that asked for it (ADR 2026-11.adrq, P3b): only the plane stops one, when no request is left for it
    /// or the plane pauses, and a stopped search hashes at most this many more counters.
    static let cancelCheckInterval: Int64 = 1 << 16
    /// How long before a stamp's window closes on our clock it is mined afresh (`REUSE_MARGIN_MS`, `:32`): a spool whose
    /// clock runs that far ahead of ours still takes the old one.
    public static let reuseMarginMilliseconds: Int64 = 3_600_000

    /// A stamp's window on our clock: its own day and the next, the yesterday a spool still takes (S-8-1).
    private static let windowDays: Int64 = 2
    private static let label = Array("knit/spool/v1/pow".utf8)

    /// The UTC day number of `nowMs` (`utcDay`, `:35`), by floor division, so a clock before 1970 counts down rather than
    /// rounding toward day 0.
    public static func utcDay(nowMs: Int64) -> Int64 {
        let (quotient, remainder) = nowMs.quotientAndRemainder(dividingBy: dayMilliseconds)
        return remainder < 0 ? quotient - 1 : quotient
    }

    /// Whether a stamp mined for `stampDay` is still worth sending at `nowMs` (`reusable`, `:44-47`): through the next day,
    /// which a spool still takes, less ``reuseMarginMilliseconds``, and never a stamp from past tomorrow, which a clock
    /// set back made.
    public static func reusable(stampDay: Int64, nowMs: Int64) -> Bool {
        guard stampDay <= utcDay(nowMs: nowMs) + 1 else {
            return false
        }
        // A day so far back that its window's end overflows closed long ago.
        let (end, pastEnd) = (stampDay + windowDays).multipliedReportingOverflow(by: dayMilliseconds)
        let (closes, pastStart) = end.subtractingReportingOverflow(reuseMarginMilliseconds)
        return !pastEnd && !pastStart && nowMs < closes
    }

    /// The stamp's digest (`digest`, `:50-54`).
    public static func digest(scopeId: [UInt8], day: Int64, n: Int64) -> [UInt8] {
        Array(SHA256.hash(data: label + scopeId + RatchetCrypto.u64be(day) + RatchetCrypto.u64be(n)))
    }

    /// A digest's leading zero bits, the first byte's highest bit first (`leadingZeroBits`, `:94-106`).
    public static func leadingZeroBits(_ digest: some Sequence<UInt8>) -> Int {
        var bits = 0
        for byte in digest {
            guard byte == 0 else {
                return bits + byte.leadingZeroBitCount
            }
            bits += UInt8.bitWidth
        }
        return bits
    }

    /// Whether `n` is a stamp for `scopeId` on `day` at `bits` (`verify`, `:57-62`). Any `n` passes at `bits` 0 or below.
    public static func verify(scopeId: [UInt8], day: Int64, n: Int64, bits: Int) -> Bool {
        bits <= 0 || leadingZeroBits(digest(scopeId: scopeId, day: day, n: n)) >= bits
    }

    /// The smallest stamp for `scopeId` on `day` at `bits` among counters `max(from, 0)..<maxTries` (`stamp`,
    /// `:73-91`, whose `startN` is `from` and whose budget is ``maxTries`` counted from 0 rather than from `from`).
    /// Answers ``Search/exhausted(tried:)`` with `tried` 0 when `bits` is below 0 or above ``maxBits`` or the range is
    /// empty, before `shouldStop` is asked; otherwise `shouldStop` is asked at the first counter and every
    /// ``cancelCheckInterval`` counters after, and true answers ``Search/cancelled(tried:)``, at `bits` 0 too. At `bits` 0
    /// the stamp is the range's first counter.
    ///
    /// Deterministic and ascending, so §13's vector pins it, and a search from `from` after one that hashed `0..<from`
    /// and found nothing answers exactly what one search from 0 would.
    ///
    /// Each counter hashes from a copy of the hasher after the fixed 57-byte prefix, with the counter written into one
    /// reused buffer. The copy saves no compression: the first 64-byte block ends inside the counter, so nothing of the
    /// prefix is compressed yet. Under swift-crypto on Linux the hasher's state is a class behind copy-on-write, so each
    /// counter allocates one state. Kotlin's `PowMiner` caches that block for 256 counters at a time; it is not ported,
    /// since it hand-rolls SHA-256, and the cost it saves is at most half.
    public static func mine(
        scopeId: [UInt8], day: Int64, bits: Int, from: Int64 = 0, shouldStop: () -> Bool = { Task.isCancelled }
    ) -> Search {
        mine(scopeId: scopeId, day: day, bits: bits, from: from, end: maxTries, shouldStop: shouldStop)
    }

    /// ``mine(scopeId:day:bits:from:shouldStop:)`` over counters `max(from, 0)..<end`, which a test ends early.
    static func mine( // swiftlint:disable:this function_parameter_count - the public search's five, and the end a test sets
        scopeId: [UInt8], day: Int64, bits: Int, from: Int64, end: Int64, shouldStop: () -> Bool
    ) -> Search {
        let start = max(from, 0)
        guard (0...maxBits).contains(bits), start < end else {
            return .exhausted(tried: 0)
        }
        var prefix = SHA256()
        prefix.update(data: label + scopeId + RatchetCrypto.u64be(day))
        var counter = [UInt8](repeating: 0, count: MemoryLayout<Int64>.size)
        for n in start..<end {
            let tried = n - start
            if tried.isMultiple(of: cancelCheckInterval), shouldStop() {
                return .cancelled(tried: tried)
            }
            for index in counter.indices {
                counter[index] = UInt8(truncatingIfNeeded: n >> Int64((counter.count - 1 - index) * UInt8.bitWidth))
            }
            var hasher = prefix
            hasher.update(data: counter)
            if leadingZeroBits(hasher.finalize()) >= bits {
                return .found(n, tried: tried + 1)
            }
        }
        return .exhausted(tried: end - start)
    }
}
