import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// What bounds ``AckSync`` and what a sealed batch carries: the riders it takes from the room's hold, the caps
/// (`PENDING_CAP`, `ESCALATED_CAP`, `OWED_CAP`, `AckSync.kt:762-796` at knit-next `cbf2a487`) and the order they evict in,
/// which Kotlin's hash maps leave to chance and this port fixes so every run repeats, and how a hold wider than one batch
/// goes over a link (knit-next #173).
@Suite struct AckSyncBoundsTests {
    private let me = fixtureNodeId(1)
    private let author = fixtureNodeId(2)
    private let other = fixtureNodeId(3)
    private let debounce = AckSync.batchDebounceMilliseconds

    // MARK: Riders

    @Test func aBatchCarriesItsAuthorsWaitingRoomTicks() {
        // `originateDeliveryTick` (`MeshManager.kt:1944-1958`): the batch is sealed to the author and carried anyway, so the
        // room ticks waiting for a ride cost it a few bytes and no row of their own.
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], originates: true)
        _ = ledger.owe("r1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("r2", author: author, escalatable: false, me: me, linked: [], now: 1, seals: seals)
        _ = ledger.owe("g1", author: author, escalatable: true, me: me, linked: [], now: 2, seals: seals)
        _ = ledger.flushDueBatches(linked: [], now: 2 + debounce, seals: seals)
        #expect(seals.originated == [["g1", "r1", "r2"]])
        #expect(ledger.ridingFor(author) == 0)
        _ = ledger.owe("r1", author: author, escalatable: false, me: me, linked: [], now: 3 + debounce, seals: seals)
        #expect(ledger.isEmpty, "a rider is done, so its re-serve owes nothing")
    }

    @Test func aBatchTakesRidersOnlyUpToItsCap() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], originates: true)
        for index in 0..<70 {
            _ = ledger.owe("r\(index)", author: author, escalatable: false, me: me, linked: [], now: Int64(index), seals: seals)
        }
        _ = ledger.owe("g1", author: author, escalatable: true, me: me, linked: [], now: 100, seals: seals)
        _ = ledger.flushDueBatches(linked: [], now: 100 + debounce, seals: seals)
        let tick = seals.originated.first ?? []
        #expect(tick.count == AckSync.maxBatchAcks && tick.first == "g1")
        #expect(Array(tick.dropFirst()) == (0..<63).map { "r\($0)" }, "the oldest riders")
        #expect(ledger.ridingFor(author) == 7)
    }

    @Test func aFailedEscalationGivesItsRidersBackWithTheirStamps() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        _ = ledger.owe("r1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("g1", author: author, escalatable: true, me: me, linked: [], now: 10, seals: seals)
        _ = ledger.flushDueBatches(linked: [], now: 10 + debounce, seals: seals)
        #expect(ledger.ridingFor(author) == 1, "the rider back in its hold")
        #expect(ledger.count == 2, "and the batch a cleartext entry")
        // Still due on its first stamp: the heal's pass sends it over a link it finds.
        let home = ledger.retryPending(linked: [author], now: AckSync.rideHoldMilliseconds, seals: seals)
        #expect(home.cleartextIds == ["g1"] && home.sealedWires.count == 1)
        #expect(seals.sealed == [["r1"]])
    }

    // MARK: Caps

    @Test func theBatchesTogetherEscalateTheOldestAtThePendingCap() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: Set((10..<30).map(fixtureNodeId)), originates: true)
        // Twenty authors, 25 group ticks each, owed round robin: the 500th escalates the oldest author's batch.
        for round in 0..<25 {
            for seed in 10..<30 {
                let now = Int64(round * 100 + seed)
                _ = ledger.owe(
                    "g\(seed)-\(round)", author: fixtureNodeId(seed), escalatable: true, me: me, linked: [], now: now, seals: seals)
            }
        }
        #expect(seals.originated.count == 1)
        #expect(seals.originated.first?.first == "g10-0", "the batch whose first tick is oldest")
        #expect(ledger.count == AckSync.pendingCapacity - 25)
    }

    @Test func theRideHoldsTogetherDropTheOldestPastThePendingCap() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author, other], seals: true)
        _ = ledger.owe("o1", author: other, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("o2", author: other, escalatable: false, me: me, linked: [], now: 1, seals: seals)
        for index in 0..<(AckSync.pendingCapacity - 1) {
            _ = ledger.owe("r\(index)", author: author, escalatable: false, me: me, linked: [], now: Int64(index + 2), seals: seals)
        }
        #expect(ledger.ridingFor(other) == 1, "the oldest hold's first id dropped")
        _ = ledger.owe("r-last", author: author, escalatable: false, me: me, linked: [], now: 1000, seals: seals)
        #expect(ledger.ridingFor(other) == 0, "and then its last: dropped, never originated")
        #expect(ledger.ridingFor(author) == AckSync.pendingCapacity)
        #expect(seals.sealed.isEmpty && seals.originated.isEmpty)
    }

    @Test func theSweepDropsOnlyAHoldsAgedOutIds() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        _ = ledger.owe("old", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("new", author: author, escalatable: false, me: me, linked: [], now: 1000, seals: seals)
        ledger.sweep(now: AckSync.owedMilliseconds + 1)
        #expect(ledger.ridingFor(author) == 1)
        #expect(ledger.linked(to: author, now: AckSync.owedMilliseconds + 2, seals: seals).sealedWires.count == 1)
        #expect(seals.sealed == [["new"]])
    }

    @Test func aLentStampIsForgottenAfterADay() {
        // A carrier that never answers leaves its stamps lent; the sweep forgets them, so a late give-back waits from then.
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        _ = ledger.owe("r1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.takeRiding(author, limit: 1) == ["r1"])
        let late = AckSync.owedMilliseconds + 1
        ledger.sweep(now: late)
        ledger.giveBackRiding(author, ["r1"], now: late)
        let hold = AckSync.rideHoldMilliseconds
        #expect(ledger.retryPending(linked: [author], now: late + hold - 1, seals: seals).isEmpty, "stamped at the give-back")
        #expect(ledger.retryPending(linked: [author], now: late + hold, seals: seals).sealedWires.count == 1)
    }

    @Test func theEscalatedLedgerForgetsItsOldestPastItsCap() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], originates: true)
        // Sixteen full batches: 1,024 ids escalated, so the first 24 are forgotten.
        for index in 0..<(16 * AckSync.maxBatchAcks) {
            _ = ledger.owe("g\(index)", author: author, escalatable: true, me: me, linked: [], now: Int64(index), seals: seals)
        }
        #expect(seals.originated.count == 16)
        _ = ledger.owe("g23", author: author, escalatable: true, me: me, linked: [], now: 2000, seals: seals)
        _ = ledger.owe("g24", author: author, escalatable: true, me: me, linked: [], now: 2001, seals: seals)
        #expect(ledger.count == 1, "the forgotten id is owed again, the remembered one is not")
    }

    @Test func theSweepForgetsEscalatedIdsAfterADay() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], originates: true)
        _ = ledger.owe("g1", author: author, escalatable: true, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.flushDueBatches(linked: [], now: debounce, seals: seals)
        _ = ledger.owe("g1", author: author, escalatable: true, me: me, linked: [], now: debounce + 1, seals: seals)
        #expect(ledger.isEmpty, "remembered within the day")
        _ = ledger.owe(
            "g1", author: author, escalatable: true, me: me, linked: [], now: debounce + AckSync.owedMilliseconds + 1, seals: seals)
        #expect(ledger.count == 1, "and owed again after it")
    }

    @Test func aRestoredEntryKeepsItsStampSoItIsEvictedFirst() {
        var ledger = AckSync(capacity: 3)
        let seals = LedgerSeals(capable: [author])
        _ = ledger.owe("g1", author: author, escalatable: true, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("o1", author: other, escalatable: false, me: me, linked: [], now: 10, seals: seals)
        _ = ledger.owe("o2", author: other, escalatable: false, me: me, linked: [], now: 20, seals: seals)
        // The escalation fails, so g1 comes back stamped 0: the oldest entry, first to go at the cap.
        _ = ledger.flushDueBatches(linked: [], now: debounce, seals: seals)
        _ = ledger.owe("o3", author: other, escalatable: false, me: me, linked: [], now: debounce + 1, seals: seals)
        #expect(ledger.linked(to: author, now: debounce + 2, seals: seals).isEmpty, "g1 was evicted")
        #expect(ledger.linked(to: other, now: debounce + 3, seals: seals).cleartextIds == ["o1", "o2", "o3"])
    }

    // MARK: A hold over a link

    @Test func aChunkThatCannotSealGoesAsCleartextAndTheOthersStaySealed() {
        // `flushBatchOverLink` restores a chunk whose seal fails as cleartext, chunk by chunk (`AckSync.kt:588-598` at
        // knit-next `3e3e044c`), so one stale "can seal" costs that chunk's ids a cleartext tick each and nothing more.
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        let width = AckSync.maxBatchAcks
        let ids = (0..<(2 * width + 22)).map { "r\($0)" }
        let middle = Array(ids[width..<(2 * width)])
        seals.refuses = { $0 == middle }
        for (index, id) in ids.enumerated() {
            _ = ledger.owe(id, author: author, escalatable: false, me: me, linked: [], now: Int64(index), seals: seals)
        }
        let ticks = ledger.linked(to: author, now: 1000, seals: seals)

        #expect(seals.sealed == [Array(ids[..<width]), Array(ids[(2 * width)...])], "the first and last chunks sealed")
        let expected =
            [AckSync.Tick(author: author, form: .sealed(LedgerSeals.wire(to: author, acks: Array(ids[..<width]))))]
            + middle.map { AckSync.Tick(author: author, form: .cleartext(ackId: $0)) }
            + [AckSync.Tick(author: author, form: .sealed(LedgerSeals.wire(to: author, acks: Array(ids[(2 * width)...]))))]
        #expect(ticks == expected, "in the order the ids came, the middle chunk one cleartext tick per id")
        #expect(ledger.isEmpty, "the link ends every one of them")
    }

    @Test func aHoldOfOneBatchStillGoesAsOneTick() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true)
        let ids = (0..<AckSync.maxBatchAcks).map { "r\($0)" }
        for id in ids {
            _ = ledger.owe(id, author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        }
        #expect(ledger.linked(to: author, now: 10, seals: seals).count == 1)
        #expect(seals.sealed == [ids], "a hold that fits one tick is not cut")
    }

    @Test func theNextBatchDueIsTheOldestBatchsDebounce() {
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author, other], originates: true)
        _ = ledger.owe("a1", author: author, escalatable: true, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("b1", author: other, escalatable: true, me: me, linked: [], now: 10, seals: seals)
        _ = ledger.owe("a2", author: author, escalatable: true, me: me, linked: [], now: 20, seals: seals)
        #expect(ledger.nextBatchDue == debounce)
        _ = ledger.flushDueBatches(linked: [], now: debounce, seals: seals)
        #expect(seals.originated == [["a1", "a2"]])
        #expect(ledger.nextBatchDue == 10 + debounce)
        _ = ledger.flushDueBatches(linked: [], now: 10 + debounce, seals: seals)
        #expect(seals.originated == [["a1", "a2"], ["b1"]] && ledger.nextBatchDue == nil)
    }

    @Test func aRoomTickNeverEscalatesHoweverLongItWaits() {
        // knit-next ADR 2026-09.aa27: the room may not cost a custody row, so its hold never originates.
        var ledger = AckSync()
        let seals = LedgerSeals(capable: [author], seals: true, originates: true)
        _ = ledger.owe("r1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        #expect(ledger.nextBatchDue == nil)
        for hour: Int64 in 1...23 {
            _ = ledger.retryPending(linked: [], now: hour * 3_600_000, seals: seals)
        }
        #expect(seals.originated.isEmpty && seals.sealed.isEmpty)
        #expect(ledger.ridingFor(author) == 1)
        _ = ledger.retryPending(linked: [], now: AckSync.owedMilliseconds + 1, seals: seals)
        #expect(ledger.isEmpty, "a day on, it is swept")
    }
}
