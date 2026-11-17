import Crypto
import Testing

@testable import KnitCrypto

/// knit-next's `SpoolPowTest` (`mesh/crypto/scope/`, at `0832b8462`; ADR 2026-11.adrq): the stamp's digest recomputed
/// by hand, leading zero bits counted bit by bit, mining that finds the smallest counter, the UTC day's floor, the reuse
/// window, and the bounds this port holds a spool's `powBits` to. §13's stamp is pinned in ``ScopeVectorTests``.
///
/// Left out with Kotlin's lane cache (`PowMiner`), which is not ported: `theMinerCountsWhatTheReferenceDigestCounts` and
/// `miningAllocatesNothingPerAttempt`. Kotlin's `startN` is `from` here, and the search's answer, its `tried` and its
/// stop are this port's own.
@Suite struct SpoolPowTests {
    static let scopeId = (0..<32).map { UInt8(truncatingIfNeeded: $0 * 7 + 9) }
    static let day: Int64 = 20_680

    @Test func theDigestIsAnIndependentRecompute() {
        let input = Array("knit/spool/v1/pow".utf8) + Self.scopeId + [0, 0, 0, 0, 0, 0, 0x50, 0xC8] + [0, 0, 0, 0, 0, 0, 0, 42]
        #expect(SpoolPow.digest(scopeId: Self.scopeId, day: Self.day, n: 42) == Array(SHA256.hash(data: input)))
    }

    @Test func leadingZeroBitsCountBitByBit() {
        #expect(SpoolPow.leadingZeroBits([0x80, 0]) == 0)
        #expect(SpoolPow.leadingZeroBits([0x01, 0xFF]) == 7)
        #expect(SpoolPow.leadingZeroBits([0x00, 0xFF]) == 8)
        #expect(SpoolPow.leadingZeroBits([0, 0, 0x40, 0]) == 17)
        #expect(SpoolPow.leadingZeroBits([UInt8](repeating: 0, count: 4)) == 32)
        #expect(SpoolPow.leadingZeroBits([UInt8]()) == 0)
    }

    @Test func miningFindsTheSmallestCounterAndItVerifies() throws {
        let n = try #require(SpoolPow.mine(scopeId: Self.scopeId, day: Self.day, bits: 8).counter)
        #expect(SpoolPow.verify(scopeId: Self.scopeId, day: Self.day, n: n, bits: 8))
        for earlier in 0..<n {
            #expect(!SpoolPow.verify(scopeId: Self.scopeId, day: Self.day, n: earlier, bits: 8))
        }
    }

    /// `miningMatchesTheReferenceLoop`: for several scopes, days, difficulties and starting counters, the first counter a
    /// plain loop over ``SpoolPow/verify(scopeId:day:n:bits:)`` finds from the same start, with every counter it passed
    /// counted in `tried`.
    @Test func miningMatchesTheReferenceLoop() {
        var generator = SplitMix64(seed: 11)
        for round in 0..<8 {
            let scope = (0..<32).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            let utcDay = Int64(generator.next() % 100_000)
            let bits = 6 + round % 5
            let from = Int64(generator.next() % 1024)
            var expected = from
            while !SpoolPow.verify(scopeId: scope, day: utcDay, n: expected, bits: bits) {
                expected += 1
            }
            let search = SpoolPow.mine(scopeId: scope, day: utcDay, bits: bits, from: from)
            #expect(search == .found(expected, tried: expected - from + 1))
        }
        #expect(SpoolPow.mine(scopeId: Self.scopeId, day: 1, bits: 0, from: 5) == .found(5, tried: 1))
    }

    /// `exhaustedBudgetReturnsNullAndZeroBitsAcceptsEverything`, with this port's bounds: 0 bits is the range's first
    /// counter, and a difficulty outside 0…24 or an empty range answers exhausted having hashed nothing, before the stop
    /// is asked, where Kotlin's `stamp` would mine to its budget.
    @Test func outOfBoundsBitsAndEmptyRangesAreExhaustedBeforeTheStopIsAsked() {
        let ones = [UInt8](repeating: 1, count: 32)
        var asked = 0
        let stop = {
            asked += 1
            return true
        }
        #expect(SpoolPow.mine(scopeId: ones, day: 1, bits: 0) == .found(0, tried: 1))
        #expect(SpoolPow.verify(scopeId: ones, day: 1, n: 0, bits: 0))
        #expect(SpoolPow.verify(scopeId: ones, day: 1, n: 0, bits: -1))
        for bits in [-1, SpoolPow.maxBits + 1, 64, 256, Int.min, Int.max] {
            #expect(SpoolPow.mine(scopeId: ones, day: 1, bits: bits, shouldStop: stop) == .exhausted(tried: 0), "\(bits) bits")
        }
        for from in [SpoolPow.maxTries, SpoolPow.maxTries + 1, .max] {
            #expect(SpoolPow.mine(scopeId: ones, day: 1, bits: 0, from: from, shouldStop: stop) == .exhausted(tried: 0))
        }
        for end: Int64 in [0, -1, .min] {
            #expect(SpoolPow.mine(scopeId: ones, day: 1, bits: 0, from: 0, end: end, shouldStop: stop) == .exhausted(tried: 0))
        }
        #expect(SpoolPow.mine(scopeId: ones, day: 1, bits: 0, from: 64, end: 64, shouldStop: stop) == .exhausted(tried: 0))
        #expect(asked == 0, "the stop is never asked")
        #expect(SpoolPow.mine(scopeId: ones, day: 1, bits: 0, from: -5) == .found(0, tried: 1), "a negative start is 0")
        #expect(SpoolPow.maxBits == 24 && SpoolPow.maxTries == 1 << 26)
    }

    /// A range with no stamp in it answers exhausted having hashed all of it, and answers the same again.
    @Test func anExhaustedRangeHashesAllOfItAndAnswersTheSameTwice() {
        let ones = [UInt8](repeating: 1, count: 32)
        let first = SpoolPow.mine(scopeId: ones, day: 1, bits: SpoolPow.maxBits, from: 16, end: 80) { false }
        #expect(first == .exhausted(tried: 64) && first.counter == nil && first.tried == 64)
        #expect(SpoolPow.mine(scopeId: ones, day: 1, bits: SpoolPow.maxBits, from: 16, end: 80) { false } == first)
    }

    @Test func theUTCDayFloors() {
        #expect(SpoolPow.utcDay(nowMs: 0) == 0)
        #expect(SpoolPow.utcDay(nowMs: SpoolPow.dayMilliseconds - 1) == 0)
        #expect(SpoolPow.utcDay(nowMs: SpoolPow.dayMilliseconds) == 1)
        #expect(SpoolPow.utcDay(nowMs: -1) == -1)
        #expect(SpoolPow.utcDay(nowMs: -SpoolPow.dayMilliseconds) == -1)
        #expect(SpoolPow.utcDay(nowMs: -SpoolPow.dayMilliseconds - 1) == -2)
        #expect(SpoolPow.utcDay(nowMs: .min) < 0 && SpoolPow.utcDay(nowMs: .max) > 0)
    }

    /// `aStampIsReusedThroughTheSpoolsWindowLessTheMargin`, and a stamp day no clock makes, which ends nothing in a trap.
    @Test func aStampIsReusedThroughTheSpoolsWindowLessTheMargin() {
        let minted: Int64 = 20_000
        let start = minted * SpoolPow.dayMilliseconds
        #expect(SpoolPow.reusable(stampDay: minted, nowMs: start), "the day it was minted")
        #expect(SpoolPow.reusable(stampDay: minted, nowMs: start + SpoolPow.dayMilliseconds + 3_600_000), "the next day")
        let closes = (minted + 2) * SpoolPow.dayMilliseconds - SpoolPow.reuseMarginMilliseconds
        #expect(SpoolPow.reusable(stampDay: minted, nowMs: closes - 1))
        #expect(!SpoolPow.reusable(stampDay: minted, nowMs: closes), "inside the margin before the window closes")
        #expect(!SpoolPow.reusable(stampDay: minted, nowMs: start + 2 * SpoolPow.dayMilliseconds), "two days on")
        #expect(SpoolPow.reusable(stampDay: minted + 1, nowMs: start), "a day ahead is still in a spool's window")
        #expect(!SpoolPow.reusable(stampDay: minted + 2, nowMs: start), "further ahead is not (a clock set back)")
        #expect(!SpoolPow.reusable(stampDay: .min, nowMs: start))
        #expect(!SpoolPow.reusable(stampDay: .max, nowMs: start))
        #expect(!SpoolPow.reusable(stampDay: minted, nowMs: .max))
        #expect(!SpoolPow.reusable(stampDay: minted, nowMs: .min), "a stamp from far ahead of a clock set back")
    }

    /// A stop already true at the start answers cancelled having hashed nothing, even at 0 bits, where any counter would
    /// do.
    @Test func aStopAtTheStartIsCancelledWithNothingTried() {
        let search = SpoolPow.mine(scopeId: Self.scopeId, day: Self.day, bits: 0, from: 7) { true }
        #expect(search == .cancelled(tried: 0) && search.counter == nil && search.tried == 0)
    }

    /// The stop is asked at the search's first counter and every ``SpoolPow/cancelCheckInterval`` counters after,
    /// counted from where the search starts; true on its k-th ask answers cancelled having hashed `(k - 1)` intervals,
    /// and resuming there answers what one unstopped search answers.
    @Test func theStopIsAskedEveryIntervalFromTheStart() {
        let interval = SpoolPow.cancelCheckInterval
        #expect(interval == 1 << 16)
        let from: Int64 = 3
        let end = from + 2 * interval + 1
        let whole = SpoolPow.mine(scopeId: Self.scopeId, day: Self.day, bits: SpoolPow.maxBits, from: from, end: end) { false }
        #expect(whole == .exhausted(tried: end - from), "no stamp in the range, so every ask is reached")
        for stopsOn in 1...3 {
            var asked = 0
            let search = SpoolPow.mine(scopeId: Self.scopeId, day: Self.day, bits: SpoolPow.maxBits, from: from, end: end) {
                asked += 1
                return asked == stopsOn
            }
            #expect(search == .cancelled(tried: Int64(stopsOn - 1) * interval), "stopped on ask \(stopsOn)")
            #expect(asked == stopsOn)
            let resumed = SpoolPow.mine(
                scopeId: Self.scopeId, day: Self.day, bits: SpoolPow.maxBits, from: from + search.tried, end: end
            ) { false }
            #expect(resumed == .exhausted(tried: end - from - search.tried))
        }
        var asked = 0
        _ = SpoolPow.mine(scopeId: Self.scopeId, day: Self.day, bits: SpoolPow.maxBits, from: from, end: end) {
            asked += 1
            return false
        }
        #expect(asked == 3, "asked at offsets 0, one interval and two")
    }

    /// With no stop given, a cancelled task stops the search at the next ask, so a caller that runs it in a task can
    /// stop it by cancelling that task. Cancelled before the first counter, it hashes nothing even at 0 bits.
    @Test func withNoStopGivenACancelledTaskStopsTheSearch() async {
        #expect(SpoolPow.mine(scopeId: Self.scopeId, day: Self.day, bits: 0) == .found(0, tried: 1))
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return SpoolPow.mine(scopeId: Self.scopeId, day: Self.day, bits: 0)
        }.value
        #expect(cancelled == .cancelled(tried: 0))
    }
}

/// A fixed sequence for the reference loop's inputs, so a failure names the same case each run.
private struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
