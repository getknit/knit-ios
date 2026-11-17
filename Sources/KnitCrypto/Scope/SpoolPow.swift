import Crypto

/// A spool's proof of work (`SpoolPow`, knit-next `mesh/crypto/scope/SpoolPow.kt` at `0832b8462`; `docs/SPOOL_PROTOCOL.md`
/// §8; ADR 2026-11.adrq): a stamp `n` whose `SHA-256("knit/spool/v1/pow" ‖ scopeId ‖ u64be(day) ‖ u64be(n))` has at
/// least `bits` leading zero bits, for the UTC day on our clock. A spool takes a stamp for its yesterday, today or
/// tomorrow (S-8-1) and asks for one only for a scope it does not hold, so a client mines about once per new scope per
/// day, and only after an `err pow` (C-8-4).
///
/// Mining is plain CPU work, about a million hashes at the usual 20 bits, so the caller runs ``mine(scopeId:day:bits:)``
/// off the `Mesh` actor.
public enum SpoolPow {
    /// One UTC day in milliseconds (`DAY_MS`, `:12`).
    public static let dayMilliseconds: Int64 = 86_400_000
    /// The most difficulty this client mines (`MAX_BITS`, `:24`). `powBits` is the spool's own claim in its HELLO, and
    /// each bit doubles the work, so past 24 bits, 16 times the recommended 20, the answer is to refuse.
    public static let maxBits = 24
    /// The most counters one stamp tries, 2^26, four times a 24-bit stamp's expected cost: the budget Kotlin's caller
    /// passes `stamp` (`POW_BUDGET`, `ScopeSync.kt:3469`).
    public static let maxTries: Int64 = 1 << 26
    /// How many counters run between looks at the task's cancellation: a dropped link or a switched-off plane stops the
    /// work within this many hashes.
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

    /// The smallest stamp from 0 for `scopeId` on `day` at `bits` (`stamp`, `:73-91`), or `nil` when `bits` is below 0 or
    /// above ``maxBits``, ``maxTries`` counters found none, or the calling task was cancelled, which is looked at every
    /// ``cancelCheckInterval`` counters. At `bits` 0, 0. Deterministic, so §13's vector pins it.
    ///
    /// Each counter hashes from a copy of the state after the fixed 57-byte prefix, into one reused buffer, so the loop
    /// allocates nothing. The copy saves no compression: the first 64-byte block ends inside the counter, so nothing of the
    /// prefix is compressed yet. Kotlin's `PowMiner` caches that block for 256 counters at a time; it is not ported, since
    /// it hand-rolls SHA-256, and the cost it saves is at most half.
    public static func mine(scopeId: [UInt8], day: Int64, bits: Int) -> Int64? {
        mine(scopeId: scopeId, day: day, bits: bits, tries: maxTries)
    }

    /// ``mine(scopeId:day:bits:)`` within `tries` counters, which a test sets small.
    static func mine(scopeId: [UInt8], day: Int64, bits: Int, tries: Int64) -> Int64? {
        guard (0...maxBits).contains(bits) else {
            return nil
        }
        var prefix = SHA256()
        prefix.update(data: label + scopeId + RatchetCrypto.u64be(day))
        var counter = [UInt8](repeating: 0, count: MemoryLayout<Int64>.size)
        for n in 0..<max(tries, 0) {
            if n.isMultiple(of: cancelCheckInterval), Task.isCancelled {
                return nil
            }
            for index in counter.indices {
                counter[index] = UInt8(truncatingIfNeeded: n >> Int64((counter.count - 1 - index) * UInt8.bitWidth))
            }
            var hasher = prefix
            hasher.update(data: counter)
            if leadingZeroBits(hasher.finalize()) >= bits {
                return n
            }
        }
        return nil
    }
}
