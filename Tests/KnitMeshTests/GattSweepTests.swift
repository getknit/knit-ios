import KnitMesh
import Testing

/// One search of every `0xFE30` service a peer serves (ADR 2026-11.prsp): a blinding iPhone's doorbell and payload sit in
/// two, so a read or a lookup ends only once each has answered, whichever holds what it looks for.
@Suite struct GattSweepTests {
    private typealias Sweep = GattSweep<Int, String>

    @Test func thePayloadInTheSecondServiceIsFound() {
        var sweep = Sweep([1, 2])
        #expect(sweep.answered(1, found: nil, failed: false) == nil, "the doorbell's service holds no payload, and one still owes")
        #expect(sweep.answered(2, found: "payload", failed: false) == .found("payload"))
        #expect(sweep.pending.isEmpty)
    }

    /// The first found wins, and the search still waits for the last answer.
    @Test func theFirstFoundWinsOnceAllHaveAnswered() {
        var sweep = Sweep([1, 2, 3])
        #expect(sweep.answered(2, found: "old", failed: false) == nil)
        #expect(sweep.answered(3, found: "new", failed: true) == nil)
        #expect(sweep.answered(1, found: nil, failed: false) == .found("old"), "a found one outweighs a failure")
    }

    @Test func noServiceHoldingItIsMissing() {
        var sweep = Sweep([1, 2])
        _ = sweep.answered(1, found: nil, failed: false)
        #expect(sweep.answered(2, found: nil, failed: false) == .missing(failed: false))
    }

    @Test func aFailureWithNothingFoundIsAFailure() {
        var sweep = Sweep([1, 2])
        _ = sweep.answered(1, found: nil, failed: true)
        #expect(sweep.answered(2, found: nil, failed: false) == .missing(failed: true))
    }

    /// A services change that took a service still owed restarts the search; one that took only answered ones does not.
    @Test func aSearchWaitsOnAnInvalidatedServiceOnlyWhileItIsOwed() {
        var sweep = Sweep([1, 2])
        #expect(sweep.waitsOnAny(of: [2, 7]))
        _ = sweep.answered(2, found: nil, failed: false)
        #expect(!sweep.waitsOnAny(of: [2, 7]))
        #expect(sweep.waitsOnAny(of: [1]))
        #expect(!sweep.waitsOnAny(of: []))
    }

    /// A second discovery's answers, or a service the search never asked, change nothing.
    @Test func anAnswerNotWaitedOnIsIgnored() {
        var sweep = Sweep([1, 2])
        #expect(sweep.answered(9, found: "stray", failed: false) == nil)
        #expect(sweep.answered(1, found: nil, failed: false) == nil)
        #expect(sweep.answered(1, found: "again", failed: false) == nil, "an answer already heard")
        #expect(sweep.pending == [2])
        #expect(sweep.answered(2, found: nil, failed: false) == .missing(failed: false))
    }
}

/// A doorbell lookup that found nothing (ADR 2026-11.prsp): a failure the next ring retries within ten seconds of the
/// link's open or a services change, an absence past it.
@Suite struct DoorbellLookupTests {
    @Test func theBoundIsTenSeconds() {
        #expect(DoorbellLookup.doorbellSettleMilliseconds == 10_000)
    }

    @Test func nothingFoundWhileSettlingIsRetried() {
        #expect(DoorbellLookup.missing(failed: false, settlingSince: 5000, now: 5000) == .retry)
        #expect(DoorbellLookup.missing(failed: false, settlingSince: 5000, now: 14_999) == .retry)
    }

    @Test func nothingFoundPastTheBoundIsAbsent() {
        #expect(DoorbellLookup.missing(failed: false, settlingSince: 5000, now: 15_000) == .absent)
        #expect(DoorbellLookup.missing(failed: false, settlingSince: nil, now: 0) == .absent, "nothing to settle")
    }

    @Test func aFailureIsAlwaysRetried() {
        #expect(DoorbellLookup.missing(failed: true, settlingSince: nil, now: 0) == .retry)
        #expect(DoorbellLookup.missing(failed: true, settlingSince: 0, now: 1_000_000) == .retry)
    }
}
