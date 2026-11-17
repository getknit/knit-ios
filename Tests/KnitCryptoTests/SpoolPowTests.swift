import Crypto
import Testing

@testable import KnitCrypto

/// knit-next's `SpoolPowTest` (`mesh/crypto/scope/`, at `0832b8462`; ADR 2026-11.adrq): the stamp's digest recomputed
/// by hand, leading zero bits counted bit by bit, mining that finds the smallest counter, the UTC day's floor, the reuse
/// window, and the bounds this port holds a spool's `powBits` to. §13's stamp is pinned in ``ScopeVectorTests``.
///
/// Left out with Kotlin's lane cache (`PowMiner`), which is not ported: `theMinerCountsWhatTheReferenceDigestCounts` and
/// `miningAllocatesNothingPerAttempt`. `startN` is not ported either, since every stamp here is mined from 0.
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
        let n = try #require(SpoolPow.mine(scopeId: Self.scopeId, day: Self.day, bits: 8))
        #expect(SpoolPow.verify(scopeId: Self.scopeId, day: Self.day, n: n, bits: 8))
        for earlier in 0..<n {
            #expect(!SpoolPow.verify(scopeId: Self.scopeId, day: Self.day, n: earlier, bits: 8))
        }
    }

    /// `miningMatchesTheReferenceLoop`: for several scopes, days and difficulties, the first counter a plain loop over
    /// ``SpoolPow/verify(scopeId:day:n:bits:)`` finds.
    @Test func miningMatchesTheReferenceLoop() {
        var generator = SplitMix64(seed: 11)
        for round in 0..<8 {
            let scope = (0..<32).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            let utcDay = Int64(generator.next() % 100_000)
            let bits = 6 + round % 5
            var expected: Int64 = 0
            while !SpoolPow.verify(scopeId: scope, day: utcDay, n: expected, bits: bits) {
                expected += 1
            }
            #expect(SpoolPow.mine(scopeId: scope, day: utcDay, bits: bits) == expected)
        }
    }

    /// `exhaustedBudgetReturnsNullAndZeroBitsAcceptsEverything`, with this port's bounds: 0 bits is stamp 0, and a
    /// difficulty outside 0…24 is refused before any work, where Kotlin's `stamp` would mine to its budget.
    @Test func theBoundsAndTheBudget() {
        let ones = [UInt8](repeating: 1, count: 32)
        #expect(SpoolPow.mine(scopeId: ones, day: 1, bits: 0) == 0)
        #expect(SpoolPow.verify(scopeId: ones, day: 1, n: 0, bits: 0))
        #expect(SpoolPow.verify(scopeId: ones, day: 1, n: 0, bits: -1))
        for bits in [-1, SpoolPow.maxBits + 1, 64, 256, Int.min, Int.max] {
            #expect(SpoolPow.mine(scopeId: ones, day: 1, bits: bits) == nil, "\(bits) bits")
        }
        #expect(SpoolPow.mine(scopeId: ones, day: 1, bits: SpoolPow.maxBits, tries: 64) == nil, "the budget runs out")
        #expect(SpoolPow.mine(scopeId: ones, day: 1, bits: 0, tries: 0) == nil)
        #expect(SpoolPow.mine(scopeId: ones, day: 1, bits: 0, tries: -1) == nil)
        #expect(SpoolPow.maxBits == 24 && SpoolPow.maxTries == 1 << 26)
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

    /// A cancelled task stops mining at the next look, so a dropped link or a switched-off plane spends no more (P2's
    /// security review). Cancelled before the first counter, it answers nothing even where 0 would do.
    @Test func aCancelledTaskStopsMining() async {
        #expect(SpoolPow.mine(scopeId: Self.scopeId, day: Self.day, bits: 0) == 0)
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return SpoolPow.mine(scopeId: Self.scopeId, day: Self.day, bits: 0)
        }.value
        #expect(cancelled == nil)
        #expect(SpoolPow.cancelCheckInterval == 1 << 16)
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
