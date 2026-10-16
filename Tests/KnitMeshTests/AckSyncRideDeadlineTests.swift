import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// knit-next's `AckSyncRideDeadlineTest` (`AckSyncRideDeadlineTest.kt` at `cbf2a487`), by name, over the ledger alone: what a
/// room tick's ride hold does once it has waited out its deadline (knit-next ADR 2026-09.y5f3). The deadline's routes are
/// the spool and the fast plane, neither of them this port's, so here a due ride keeps waiting for a link or a carrier,
/// and a link ends the wait.
///
/// Not ported, as the spool's or the fast plane's: `aRideNobodyCarriesIsPushedToTheSpoolWhenItsAuthorIsPresentThere` and
/// `aSpoolPushThatFailsAfterSealingKeepsTheSignedTickAsAnOwedBatch` (the spool's),
/// `aRideNobodyCarriesGoesOverTheFastPlaneWhenItsAuthorIsOnlyReachable`, `aFastPlaneRideIsDroppedOnceALinkCarriesIt` and
/// `theRideDeadlineWakesWithoutAHeal` (the fast plane's: the deadline has no route here to wake for), and
/// `theSpoolIsPreferredOverTheAirWhenBothCouldReachTheAuthor` and `aRideWiderThanOneTickIsSentInChunks` (both planes': only
/// their routes cut a hold into ticks; over a link a hold goes as one, `flushBatchOverLink`).
@Suite struct AckSyncRideDeadlineTests {
    private let me = fixtureNodeId(1)
    private let author = fixtureNodeId(2)
    private let hold = AckSync.rideHoldMilliseconds

    @Test func aRideNobodyCarriesKeepsWaitingWhenItsAuthorIsNowhere() {
        // aa27's rule outlives the deadline: no route, no seal. What ends the wait here is a link, as one tick.
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("m2", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.retryPending(linked: [], now: hold + 1, seals: seals).isEmpty)
        #expect(seals.sealed.isEmpty, "no chain key is spent on nobody")
        #expect(ledger.ridingFor(author) == 2, "both still wait")

        let home = ledger.linked(to: author, now: hold + 2, seals: seals)
        #expect(home == [AckSync.Tick(author: author, form: .sealed(LedgerSeals.wire(to: author, acks: ["m1", "m2"])))])
        #expect(seals.sealed == [["m1", "m2"]])
        #expect(ledger.ridingFor(author) == 0)
    }

    @Test func aRideGivenBackKeepsItsOriginalStampSoTheDeadlineDoesNotMove() {
        // A carrier took the id and its seal fell through just before the deadline. Stamping the give-back now would
        // restart the wait every time that happened. The deadline's route here is a live link the heal's pass finds.
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.takeRiding(author, limit: 4) == ["m1"])
        ledger.giveBackRiding(author, ["m1"], now: hold - 1)
        #expect(ledger.retryPending(linked: [author], now: hold + 1, seals: seals).sealedWires.count == 1, "due on the original stamp")
        #expect(seals.sealed == [["m1"]])
    }

    @Test func anIdACarrierRodeIsNeverReHeld() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.takeRiding(author, limit: 4) == ["m1"])
        ledger.rode(["m1"], now: 10)
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 20, seals: seals)
        #expect(ledger.ridingFor(author) == 0, "the author has it; a re-serve parks nothing")
        #expect(ledger.isEmpty)
    }

    // MARK: This port's

    @Test func aRideNotYetDueWaitsForItsLinkUpEvenWhenLinked() {
        // The heal's pass sends a hold over a link only once it is due; the link's own arrival sends it at once.
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.retryPending(linked: [author], now: hold - 1, seals: seals).isEmpty)
        #expect(ledger.linked(to: author, now: hold - 1, seals: seals).sealedWires.count == 1)
    }

    @Test func aGiveBackOfAnIdNoCarrierTookWaitsFromNow() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        ledger.giveBackRiding(author, ["m9"], now: 500)
        #expect(ledger.retryPending(linked: [author], now: 499 + hold, seals: seals).isEmpty, "stamped at its give-back")
        #expect(ledger.retryPending(linked: [author], now: 500 + hold, seals: seals).sealedWires.count == 1)
    }

    @Test func anIdHeldAgainWhileLentKeepsOneEntryAtItsFirstStamp() {
        // Kotlin's hold is a map, so a give-back of an id held again keeps one entry, at the stamp it was lent with.
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.takeRiding(author, limit: 1) == ["m1"])
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 10, seals: seals)
        ledger.giveBackRiding(author, ["m1"], now: 20)
        #expect(ledger.ridingFor(author) == 1)
        #expect(ledger.retryPending(linked: [author], now: hold, seals: seals).sealedWires.count == 1, "due on its first stamp")
    }

    @Test func aHoldWhoseSealFailsOverTheLinkGoesAsCleartextTicks() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: false)
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("m2", author: author, escalatable: false, me: me, linked: [], now: 1, seals: seals)
        #expect(ledger.linked(to: author, now: 10, seals: seals).cleartextIds == ["m1", "m2"])
        #expect(ledger.isEmpty)
    }
}
