import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// knit-next's `AckSyncTest` (`AckSyncTest.kt` at `cbf2a487`), by name, over the ledger alone: the owed, escalated and ride
/// forms, with the seams a test hands in (``LedgerSeals``). The ledger answers what a transport would carry, so "the author
/// received" reads the ticks it answered toward a linked author, and that a tick is signed and point to point is the
/// engine's, which `MeshEngineTickTests` pins.
///
/// Not ported, as the fast plane's: `aSealedTickBacksOffInsteadOfResendingEveryHeartbeat` and
/// `aCleartextTickBacksOffLikeTheSealedOne` count best-effort sends toward an author with no link, which the back-off paces
/// and this port never makes. `batchedTicksNeverTakeTheCoordinationPlane` keeps its name for what it still pins here: a
/// batch sends nothing before its debounce.
@Suite struct AckSyncTests {
    private let me = fixtureNodeId(1)
    private let author = fixtureNodeId(2)
    private let debounce = AckSync.batchDebounceMilliseconds
    private let day: Int64 = 25 * 3_600_000

    private func cleartext(_ ids: String...) -> [AckSync.Tick] {
        ids.map { AckSync.Tick(author: author, form: .cleartext(ackId: $0)) }
    }

    private func sealed(_ ids: String...) -> [AckSync.Tick] {
        [AckSync.Tick(author: author, form: .sealed(LedgerSeals.wire(to: author, acks: ids)))]
    }

    // MARK: AckSyncTest

    @Test func tickReachesAuthorWhenAlreadyALiveNeighbor() {
        var ledger = AckSync()
        let ticks = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [author], now: 0, seals: LedgerSeals())
        #expect(ticks == cleartext("m1"))
        #expect(ledger.isEmpty, "a tick over a live link is done")
    }

    @Test func tickIsHeldWhileAuthorUnreachableThenDeliveredOnReconnect() {
        var ledger = AckSync()
        let seals = LedgerSeals()
        let held = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        #expect(held.isEmpty, "nothing goes while the author is out of range")
        #expect(ledger.linked(to: author, now: 10, seals: seals) == cleartext("m1"))
    }

    @Test func retryPendingResendsToAReconnectedAuthor() {
        var ledger = AckSync()
        let seals = LedgerSeals()
        #expect(ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals).isEmpty)
        #expect(ledger.retryPending(linked: [author], now: 10, seals: seals) == cleartext("m1"))
    }

    @Test func tickDeliveredOverALiveLinkIsNotResentForever() {
        var ledger = AckSync()
        let seals = LedgerSeals()
        #expect(ledger.owe("m1", author: author, escalatable: false, me: me, linked: [author], now: 0, seals: seals) == cleartext("m1"))
        #expect(ledger.retryPending(linked: [author], now: 10, seals: seals).isEmpty, "one tick, once it has a live path home")
    }

    @Test func neverAcksOurOwnMessage() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [me], seals: true, originates: true)
        #expect(ledger.owe("m1", author: me, escalatable: true, me: me, linked: [me], now: 0, seals: seals).isEmpty)
        #expect(ledger.retryPending(linked: [me], now: debounce + 1, seals: seals).isEmpty)
        #expect(ledger.isEmpty && seals.sealed.isEmpty && seals.originated.isEmpty)
    }

    @Test func agedOutTickIsSweptNotResent() {
        var ledger = AckSync()
        let seals = LedgerSeals()
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.retryPending(linked: [author], now: day, seals: seals).isEmpty, "swept, not resent")
    }

    @Test func aSealedTickIsSealedOnceAndResentVerbatim() {
        // Sealing spends a chain key, so the tick is sealed when owed and every retry sends those bytes. canSeal is false
        // here, the path an author judged unable to escalate takes even though its seal succeeds.
        var ledger = AckSync()
        let seals = LedgerSeals(seals: true)
        #expect(ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals).isEmpty)
        #expect(ledger.retryPending(linked: [], now: 1, seals: seals).isEmpty)
        #expect(ledger.retryPending(linked: [], now: 2, seals: seals).isEmpty)
        #expect(ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 3, seals: seals).isEmpty, "a re-owe")
        #expect(ledger.retryPending(linked: [author], now: 4, seals: seals) == sealed("m1"), "the same bytes go home")
        #expect(ledger.retryPending(linked: [author], now: 5, seals: seals).isEmpty)
        #expect(seals.sealed == [["m1"]], "one seal per owed tick, however many retries")
    }

    @Test func aNullSealFallsBackToTheCleartextReceipt() {
        var ledger = AckSync()
        let ticks = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [author], now: 0, seals: LedgerSeals())
        #expect(ticks == cleartext("m1") && ticks.sealedWires.isEmpty)
    }

    @Test func retriesDrainOldestFirst() {
        var ledger = AckSync()
        let seals = LedgerSeals()
        _ = ledger.owe("m-old", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("m-new", author: author, escalatable: false, me: me, linked: [], now: 1000, seals: seals)
        #expect(ledger.retryPending(linked: [author], now: 2000, seals: seals) == cleartext("m-old", "m-new"))
    }

    @Test func anAbsentCapableAuthorsTicksBatchAndOriginateOnce() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], originates: true)
        for id in ["m1", "m2", "m3"] {
            #expect(ledger.owe(id, author: author, escalatable: true, me: me, linked: [], now: 0, seals: seals).isEmpty)
        }
        #expect(seals.originated.isEmpty, "nothing before the debounce")
        #expect(ledger.retryPending(linked: [], now: debounce + 1, seals: seals).isEmpty)
        #expect(seals.originated == [["m1", "m2", "m3"]], "the heal's backstop escalates the due batch")
        // The exists-gate acknowledges again at every custody re-serve.
        _ = ledger.owe("m1", author: author, escalatable: true, me: me, linked: [], now: debounce + 2, seals: seals)
        _ = ledger.retryPending(linked: [], now: 2 * debounce + 3, seals: seals)
        #expect(seals.originated.count == 1, "an escalated id never seals or originates again")
        #expect(ledger.isEmpty)
    }

    @Test func aRoomTickTowardAnAbsentAuthorWaitsForARideInsteadOfSealing() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        #expect(ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals).isEmpty)
        #expect(ledger.owe("m2", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals).isEmpty)
        #expect(seals.sealed.isEmpty, "no chain key is spent on a tick with nowhere to go")
        #expect(ledger.ridingFor(author) == 2, "both wait for a ride")
    }

    @Test func aWaitingRoomTickIsHandedToTheNextFrameGoingThatWay() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        for id in ["m1", "m2", "m3"] {
            _ = ledger.owe(id, author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        }
        #expect(ledger.takeRiding(author, limit: 2) == ["m1", "m2"], "oldest first, and only what the carrier has room for")
        #expect(ledger.ridingFor(author) == 1)
        // The frame fell back to a form that cannot carry them: back to the hold, never onward.
        ledger.giveBackRiding(author, ["m1", "m2"], now: 10)
        #expect(ledger.ridingFor(author) == 3)
        #expect(seals.sealed.isEmpty, "a ride is never a send of its own")
    }

    @Test func aRoomTickWaitingForARideIsNotReHeldByACustodyReServe() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        for now: Int64 in [0, 1, 2] {
            _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: now, seals: seals)
        }
        #expect(ledger.ridingFor(author) == 1, "one entry however often custody re-serves it")
    }

    @Test func aLinkEndsTheWaitAsOneBatchedTick() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("m2", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.linked(to: author, now: 10, seals: seals) == sealed("m1", "m2"))
        #expect(seals.sealed == [["m1", "m2"]], "one seal covering the batch")
        #expect(ledger.ridingFor(author) == 0, "and nothing left waiting")
    }

    @Test func aRideWiderThanTheReceiversCapGoesOverTheLinkInChunks() {
        // The author applies at most MAX_RECEIPT_ACKS ids from one tick, and nothing re-owes the rest once the hold is gone
        // (knit-next #173, `AckSyncTest.kt:341-370` at `3e3e044c`): the link route cuts the hold as the spool and air
        // routes do.
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        // One past the receiver's MAX_RECEIPT_ACKS, the most ids it applies from one tick.
        let owedIds = (0...(2 * AckSync.maxBatchAcks)).map { "m\($0)" }
        for id in owedIds {
            _ = ledger.owe(id, author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        }
        let ticks = ledger.linked(to: author, now: 10, seals: seals)

        #expect(seals.sealed.allSatisfy { $0.count <= AckSync.maxBatchAcks }, "no tick wider than one batch")
        #expect(seals.sealed.flatMap(\.self) == owedIds, "together they carry every id")
        #expect(ticks.sealedWires.count == seals.sealed.count && ticks.count == ticks.sealedWires.count, "each seal goes")
        #expect(ledger.ridingFor(author) == 0, "and nothing left waiting")
    }

    @Test func aLegacyAuthorsRoomTickKeepsTheCleartextBestEffortForm() {
        // A ride exists only inside a frame sealed to its author, so an author who cannot read one keeps today's path.
        var ledger = AckSync()
        let seals = LedgerSeals()
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.ridingFor(author) == 0, "nothing waits for a ride it could never take")
        #expect(ledger.linked(to: author, now: 10, seals: seals) == cleartext("m1"))
    }

    @Test func theDebounceWakeFlushesWithoutAHeal() {
        // Kotlin's wake is the engine's deadline here: the batch says when it is due, and goes then.
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], originates: true)
        #expect(ledger.nextBatchDue == nil)
        _ = ledger.owe("m1", author: author, escalatable: true, me: me, linked: [], now: 100, seals: seals)
        #expect(ledger.nextBatchDue == 100 + debounce)
        #expect(ledger.flushDueBatches(linked: [], now: 99 + debounce, seals: seals).isEmpty && seals.originated.isEmpty)
        #expect(ledger.flushDueBatches(linked: [], now: 100 + debounce, seals: seals).isEmpty)
        #expect(seals.originated == [["m1"]])
        #expect(ledger.nextBatchDue == nil)
    }

    @Test func anEarlyNeighborJoinFlushesTheBatchOverTheLinkNotCustody() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true, originates: true)
        _ = ledger.owe("m1", author: author, escalatable: true, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("m2", author: author, escalatable: true, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.linked(to: author, now: 10, seals: seals) == sealed("m1", "m2"), "one batched tick over the link")
        #expect(seals.originated.isEmpty, "nothing escalated into custody")
        #expect(ledger.nextBatchDue == nil)
    }

    @Test func aFailedEscalationFallsBackToPerIdCleartextTicks() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author])
        _ = ledger.owe("m1", author: author, escalatable: true, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("m2", author: author, escalatable: true, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.retryPending(linked: [], now: debounce + 1, seals: seals).isEmpty, "cleartext entries, still unreachable")
        #expect(ledger.count == 2)
        #expect(ledger.retryPending(linked: [author], now: debounce + 2, seals: seals).cleartextIds.sorted() == ["m1", "m2"])
    }

    @Test func aFullBatchFlushesImmediately() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], originates: true)
        for index in 0..<AckSync.maxBatchAcks {
            _ = ledger.owe("m\(index)", author: author, escalatable: true, me: me, linked: [], now: 0, seals: seals)
        }
        #expect(seals.originated.count == 1, "a full batch goes with no clock advance")
        #expect(seals.originated.first?.count == AckSync.maxBatchAcks)
        _ = ledger.owe("m-next", author: author, escalatable: true, me: me, linked: [], now: 0, seals: seals)
        #expect(seals.originated.count == 1, "the next ack opens a fresh batch, not yet due")
        #expect(ledger.count == 1)
    }

    @Test func batchedTicksNeverTakeTheCoordinationPlane() {
        // Read here as: a batch waits for its debounce or a live link, and nothing goes before.
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true, originates: true)
        _ = ledger.owe("m1", author: author, escalatable: true, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("m2", author: author, escalatable: true, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.retryPending(linked: [], now: 1, seals: seals).isEmpty)
        #expect(seals.sealed.isEmpty && seals.originated.isEmpty)
    }

    @Test func aLiveCapableAuthorKeepsTheImmediateSealedSingleTick() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true, originates: true)
        #expect(ledger.owe("m1", author: author, escalatable: true, me: me, linked: [author], now: 0, seals: seals) == sealed("m1"))
        #expect(seals.originated.isEmpty, "no escalation for a live author")
        #expect(ledger.isEmpty)
    }

    @Test func batchedIdsAgeOutWithTheOwedTtl() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], originates: true)
        _ = ledger.owe("m1", author: author, escalatable: true, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.retryPending(linked: [], now: day, seals: seals)
        #expect(seals.originated.isEmpty, "an aged-out batch is swept, not escalated")
        #expect(ledger.isEmpty)
    }

    @Test func aBackedOffTickStillGoesHomeTheMomentALinkExists() {
        var ledger = AckSync()
        let seals = LedgerSeals(seals: true)
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.retryPending(linked: [author], now: 60_000, seals: seals) == sealed("m1"), "a live link never waits")
        #expect(ledger.retryPending(linked: [author], now: 60_001, seals: seals).isEmpty, "and the entry is done")
    }

    @Test func aBackedOffCleartextTickStillGoesHomeTheMomentALinkExists() {
        var ledger = AckSync()
        let seals = LedgerSeals()
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.retryPending(linked: [author], now: 60_000, seals: seals) == cleartext("m1"))
        #expect(ledger.retryPending(linked: [author], now: 60_001, seals: seals).isEmpty)
    }
}
