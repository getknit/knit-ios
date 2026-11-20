import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Each constant the `custody-carry-policy` contract names, pinned (its "Constants, for the parity review").
@Suite struct CustodyCarryConstantsTests {
    @Test func theConstantsAreTheContracts() {
        #expect(CustodySync.roundBytes == 16_384)
        #expect(CustodySync.roundMilliseconds == 2000)
        #expect(CustodyAnswers.maxAgeMilliseconds == 120_000)
        #expect(CustodyLimits().spreadMax == 8)
        #expect(CarryLedger.judgeAfterMilliseconds == 20_000)
        #expect(CarryLedger.notKeptLapseMilliseconds == 600_000)
        #expect(CarryLedger.maxMemoPeers == 64)
        #expect(CarryLedger.maxRosterMembers == 8)
        #expect(CarryLedger.creditMilliseconds == CustodySync.roundMilliseconds)
        #expect(ReofferBackoff.baseMilliseconds == 60_000)
        #expect(ReofferBackoff.maxMilliseconds == 600_000)
        #expect(ReofferBackoff.toleranceMilliseconds == 30_000)
        #expect(HeldDigests.lineBytes == 131_072)
        #expect(MeshConfiguration().reofferMilliseconds == ReofferBackoff.baseMilliseconds, "the tick is the base interval")
    }

    @Test func theSourceCountsInItsOwnWrite() {
        #expect(CarryLedger.sourceCountsInItsOwnWrite)
    }
}

/// The carry ledger's holders and death feed (contract §3), case for case with the Android order's step 9.
@Suite struct CarryLedgerHolderTests: CustodySyncCase {
    private var carol: NodeId { fixtureNodeId(3) }
    private func keys(_ ids: String...) -> Set<ExactKey> { Set(ids.map(ExactKey.init)) }

    @Test func aDigestListingAnIdWeHoldAddsItsPeer() {
        var ledger = CarryLedger(own: alice)
        _ = ledger.noteDigest(listing: keys("a"), from: bob, live: keys("a", "b"), now: 0, spreadMax: 8)
        #expect(ledger.holders(of: "a") == [bob])
        #expect(ledger.spread(of: "b") == 0)
    }

    @Test func aLaterDigestLackingAnIdRemovesItsPeerButNotAnotherPeer() {
        var ledger = CarryLedger(own: alice)
        _ = ledger.noteDigest(listing: keys("a"), from: bob, live: keys("a"), now: 0, spreadMax: 8)
        _ = ledger.noteDigest(listing: keys("a"), from: carol, live: keys("a"), now: 0, spreadMax: 8)
        _ = ledger.noteDigest(listing: [], from: bob, live: keys("a"), now: 1, spreadMax: 8)
        #expect(ledger.holders(of: "a") == [carol])
    }

    @Test func anIdPendingIsNotRemovedByTheLatestWord() {
        var ledger = CarryLedger(own: alice)
        _ = ledger.noteDigest(listing: keys("a"), from: bob, live: keys("a"), now: 0, spreadMax: 8)
        ledger.released([CustodySync.Release(id: "a", addressed: false)], to: bob, now: 0, linked: [])
        _ = ledger.noteDigest(listing: [], from: bob, live: keys("a"), now: 1000, spreadMax: 8)
        #expect(ledger.holders(of: "a") == [bob], "released 1 s before: not judged, so not the peer's word yet")
    }

    @Test func theSourceCountsInTheSnapshotOfItsOwnWriteAndIsRecordedOnlyIfHeld() {
        var ledger = CarryLedger(own: alice)
        let carry = ledger.carry(counting: bob, for: "x")
        #expect(carry.holders(of: "x") == 1)
        #expect(carry.holders(of: "y") == 0)
        let frame = frame("x").envelope
        ledger.noteWrite(CustodyStoreResult(held: false, changed: true, evicted: ["x"]), of: frame, from: bob, spreadMax: 8)
        #expect(ledger.spread(of: "x") == 0, "evicted by its own write: nothing recorded")
        ledger.noteWrite(CustodyStoreResult(held: true, changed: true), of: frame, from: bob, spreadMax: 8)
        #expect(ledger.holders(of: "x") == [bob])
        #expect(ledger.carry(counting: bob, for: "x").holders(of: "x") == 1, "counted once")
        #expect(ledger.carry(counting: alice, for: "z").holders(of: "z") == 0, "never ourselves")
    }

    @Test func aCreditedHandOffAddsThePeerOneIntervalLater() {
        var ledger = CarryLedger(own: alice)
        ledger.released([CustodySync.Release(id: "a", addressed: false)], to: bob, now: 1000, linked: [])
        #expect(ledger.nextCredit == 1000 + CarryLedger.creditMilliseconds)
        ledger.credit(now: 2999, spreadMax: 8)
        #expect(ledger.spread(of: "a") == 0)
        ledger.credit(now: 3000, spreadMax: 8)
        #expect(ledger.holders(of: "a") == [bob])
        #expect(ledger.nextCredit == nil)
    }

    @Test func aRoundWhoseLinkWentFirstCreditsNothing() {
        var ledger = CarryLedger(own: alice)
        ledger.released([CustodySync.Release(id: "a", addressed: true)], to: bob, now: 1000, linked: [])
        ledger.linkDown(bob)
        ledger.credit(now: 10_000, spreadMax: 8)
        #expect(ledger.spread(of: "a") == 0)
        #expect(ledger.nextCredit == nil)
    }

    @Test func aNinthHolderIsNotRecorded() {
        var ledger = CarryLedger(own: alice)
        for peer in 0..<9 {
            _ = ledger.noteDigest(listing: keys("a"), from: fixtureNodeId(40 + peer), live: keys("a"), now: 0, spreadMax: 8)
        }
        #expect(ledger.spread(of: "a") == 8)
        #expect(!ledger.holders(of: "a").contains(fixtureNodeId(48)))
    }

    @Test func entriesDieWithTheirRow() {
        var ledger = CarryLedger(own: alice)
        let group = frame("g", members: [alice, bob]).envelope
        ledger.noteWrite(CustodyStoreResult(held: true, changed: true), of: group, from: bob, spreadMax: 8)
        ledger.released([CustodySync.Release(id: "g", addressed: false)], to: carol, now: 0, linked: [])
        #expect(ledger.roster(of: ExactKey("g")) != nil)
        ledger.forget("g")
        ledger.credit(now: 10_000, spreadMax: 8)
        #expect(ledger.spread(of: "g") == 0, "an uncredited hand-off dies with the row")
        #expect(ledger.roster(of: ExactKey("g")) == nil)
        // A write that evicts it says so too.
        ledger.noteWrite(CustodyStoreResult(held: true, changed: true), of: group, from: bob, spreadMax: 8)
        ledger.noteWrite(CustodyStoreResult(held: true, changed: true, evicted: ["g"]), of: frame("h").envelope, from: nil, spreadMax: 8)
        #expect(ledger.spread(of: "g") == 0)
        #expect(ledger.count < 1, "no entry left")
        // And one written again starts clear, whatever a rolled-back unit left.
        ledger.noteWrite(CustodyStoreResult(held: true, changed: true), of: group, from: bob, spreadMax: 8)
        ledger.clear("g")
        #expect(ledger.spread(of: "g") == 0)
        #expect(ledger.roster(of: ExactKey("g")) == nil)
    }

    @Test func aPruneKeepsOnlyTheLiveIds() {
        var ledger = CarryLedger(own: alice)
        _ = ledger.noteDigest(listing: keys("a", "b"), from: bob, live: keys("a", "b"), now: 0, spreadMax: 8)
        ledger.released([CustodySync.Release(id: "b", addressed: false)], to: carol, now: 0, linked: [])
        ledger.prune(keeping: keys("a"))
        ledger.credit(now: 10_000, spreadMax: 8)
        #expect(ledger.spread(of: "a") == 1)
        #expect(ledger.spread(of: "b") == 0)
    }

    @Test func ourselvesAndAnEmptyRoundAreNeverRecorded() {
        var ledger = CarryLedger(own: alice)
        _ = ledger.noteDigest(listing: keys("a"), from: alice, live: keys("a"), now: 0, spreadMax: 8)
        #expect(ledger.spread(of: "a") == 0)
        ledger.released([], to: bob, now: 0, linked: [])
        #expect(!ledger.hasMemo(for: bob) && ledger.nextCredit == nil)
    }

    @Test func aRosterIsRememberedUpToEightMembers() {
        var ledger = CarryLedger(own: alice)
        let eight = (0..<8).map { fixtureNodeId(60 + $0) }
        let nine = (0..<9).map { fixtureNodeId(60 + $0) }
        ledger.remember(frame("g8", from: eight[0], members: eight).envelope)
        ledger.remember(frame("g9", from: nine[0], members: nine).envelope)
        ledger.remember(frame("dm", to: bob).envelope)
        #expect(ledger.roster(of: ExactKey("g8"))?.count == 8)
        #expect(ledger.roster(of: ExactKey("g9")) == nil)
        #expect(ledger.roster(of: ExactKey("dm")) == nil)
    }
}

/// The not-kept memo (contract §6), case for case with the Android order's step 9.
@Suite struct CarryLedgerMemoTests: CustodySyncCase {
    private func keys(_ ids: String...) -> Set<ExactKey> { Set(ids.map(ExactKey.init)) }
    private func release(_ ids: String..., addressed: Bool = false) -> [CustodySync.Release] {
        ids.map { CustodySync.Release(id: $0, addressed: addressed) }
    }

    @Test func aPendingIdIsWithheldAndAnAddressedOneNeverIs() {
        var ledger = CarryLedger(own: alice)
        ledger.released(release("a"), to: bob, now: 0, linked: [])
        ledger.released(release("d", addressed: true), to: bob, now: 0, linked: [])
        #expect(ledger.withholds(ExactKey("a"), from: bob, now: 1))
        #expect(!ledger.withholds(ExactKey("d"), from: bob, now: 1))
        #expect(!ledger.withholds(ExactKey("a"), from: zed, now: 1), "one memo per peer")
    }

    @Test func aDigestInsideTheJudgingDelayJudgesNothing() {
        var ledger = CarryLedger(own: alice)
        ledger.released(release("a"), to: bob, now: 0, linked: [])
        let marked = ledger.noteDigest(listing: [], from: bob, live: keys("a"), now: 19_999, spreadMax: 8)
        #expect(marked == 0)
        #expect(ledger.isPending(ExactKey("a"), for: bob, now: 19_999))
    }

    @Test func keptNotKeptAndNoLongerHeld() {
        var ledger = CarryLedger(own: alice)
        _ = ledger.noteDigest(listing: keys("n"), from: bob, live: keys("k", "n", "g"), now: 0, spreadMax: 8)
        ledger.released(release("k", "n", "g"), to: bob, now: 0, linked: [])
        let marked = ledger.noteDigest(listing: keys("k"), from: bob, live: keys("k", "n"), now: 20_000, spreadMax: 8)
        #expect(marked == 1)
        #expect(!ledger.withholds(ExactKey("k"), from: bob, now: 20_000), "kept: it leaves pending")
        #expect(ledger.withholds(ExactKey("n"), from: bob, now: 20_000), "not kept")
        #expect(!ledger.holders(of: "n").contains(bob))
        #expect(!ledger.withholds(ExactKey("g"), from: bob, now: 20_000), "no longer held: it just leaves")
    }

    @Test func aNotKeptMarkLapsesAfterTenMinutesAndALaterDigestDoesNotRefreshIt() {
        var ledger = CarryLedger(own: alice)
        ledger.released(release("n"), to: bob, now: 0, linked: [])
        _ = ledger.noteDigest(listing: [], from: bob, live: keys("n"), now: 20_000, spreadMax: 8)
        _ = ledger.noteDigest(listing: [], from: bob, live: keys("n"), now: 300_000, spreadMax: 8)
        #expect(ledger.withholds(ExactKey("n"), from: bob, now: 619_999))
        #expect(!ledger.withholds(ExactKey("n"), from: bob, now: 620_000))
    }

    @Test func aPendingIdEndsUnjudgedTenMinutesAfterItsRelease() {
        var ledger = CarryLedger(own: alice)
        ledger.released(release("a"), to: bob, now: 0, linked: [])
        #expect(ledger.withholds(ExactKey("a"), from: bob, now: 599_999))
        #expect(!ledger.withholds(ExactKey("a"), from: bob, now: 600_000))
        let marked = ledger.noteDigest(listing: [], from: bob, live: keys("a"), now: 600_000, spreadMax: 8)
        #expect(marked == 0, "neither kept nor not kept")
        #expect(!ledger.withholds(ExactKey("a"), from: bob, now: 600_001))
    }

    @Test func aLinkDownDropsTheMemo() {
        var ledger = CarryLedger(own: alice)
        ledger.released(release("a"), to: bob, now: 0, linked: [])
        _ = ledger.noteDigest(listing: [], from: bob, live: keys("a"), now: 20_000, spreadMax: 8)
        ledger.released(release("b"), to: bob, now: 20_000, linked: [])
        ledger.linkDown(bob)
        #expect(!ledger.hasMemo(for: bob))
        #expect(!ledger.withholds(ExactKey("a"), from: bob, now: 20_001))
        #expect(!ledger.withholds(ExactKey("b"), from: bob, now: 20_001))
    }

    @Test func aLinkedPeersMemoSurvivesSixtyFourFreshIdentitiesLinkingAndUnlinking() {
        var ledger = CarryLedger(own: alice)
        ledger.released(release("a"), to: bob, now: 0, linked: [])
        for index in 0..<64 {
            let fresh = fixtureNodeId(100 + index)
            ledger.released(release("x"), to: fresh, now: Int64(index + 1), linked: [bob, fresh])
            ledger.linkDown(fresh)
        }
        #expect(ledger.hasMemo(for: bob))
    }

    @Test func theMemoKeepsAtMostSixtyFourPeersTheLeastRecentOfAnUnlinkedOneOutFirst() {
        var ledger = CarryLedger(own: alice)
        let peers = (0..<65).map { fixtureNodeId(100 + $0) }
        for (index, peer) in peers.enumerated() {
            // The first is linked and the oldest: the second, the oldest unlinked, goes.
            ledger.released(release("x"), to: peer, now: Int64(index), linked: [peers[0], peer])
        }
        #expect(ledger.hasMemo(for: peers[0]))
        #expect(!ledger.hasMemo(for: peers[1]))
        #expect(peers[2...].allSatisfy { ledger.hasMemo(for: $0) })
        // Every peer linked: the least recent of all goes.
        ledger.released(release("x"), to: fixtureNodeId(200), now: 100, linked: Set(peers + [fixtureNodeId(200)]))
        #expect(!ledger.hasMemo(for: peers[0]))
    }
}

/// The answer book (contract §2).
@Suite struct CustodyAnswersTests: CustodySyncCase {
    @Test func aDigestOpensAnAnswerDueNowAndANewerOneReplacesItWithoutBringingTheRoundForward() {
        var answers = CustodyAnswers()
        let opened = answers.receive([ExactKey("a")], from: bob, now: 1000)
        #expect(opened)
        #expect(answers.answer(for: bob)?.due == 1000)
        answers.noteArrived("c", from: bob)
        answers.noteArrived("gone", from: bob)
        var round = CustodySync.DigestReply(
            keysAhead: [alice, bob], released: ["b", "gone-too"].map { CustodySync.Release(id: $0, addressed: false) }, bytes: 100)
        round.live = [ExactKey("b"), ExactKey("c")]
        round.senders = [ExactKey(alice.string)]
        answers.released(round, to: bob, now: 1000)
        let trimmed = answers.answer(for: bob)
        #expect(trimmed?.released == [ExactKey("b")], "trimmed to what custody holds")
        #expect(trimmed?.arrivedSince == [ExactKey("c")])
        #expect(trimmed?.keysSent == [ExactKey(alice.string)], "and to its senders")
        #expect(answers.timings.map(\.peer) == [bob] && answers.timings.first?.due == 3000)
        #expect(answers.answer(for: bob)?.due == 3000)
        let reopened = answers.receive([], from: bob, now: 2000)
        #expect(!reopened)
        let answer = answers.answer(for: bob)
        #expect(answer?.due == 3000, "a peer cannot raise the pace by sending digests")
        #expect(answer?.arrivedAt == 2000)
        #expect(answer?.listed.isEmpty == true)
        #expect(answer?.released == [ExactKey("b")], "what the answer released stays released")
        #expect(answer?.keysSent == [ExactKey(alice.string)])
        #expect(answer?.arrivedSince.isEmpty == true, "what arrived since the older digest, the newer one lists")
        #expect(answers.nextDeadline == 3000)
    }

    @Test func theNextRoundWaitsInProportionToAnOversizeOne() {
        #expect(CustodyAnswers.wait(after: 1) == 2000)
        #expect(CustodyAnswers.wait(after: 16_384) == 2000)
        #expect(CustodyAnswers.wait(after: 65_536) == 8000)
    }

    @Test func anAnswerAgesOutTwoMinutesAfterItsLatestDigest() throws {
        var answers = CustodyAnswers()
        answers.receive([], from: bob, now: 0)
        answers.released(CustodySync.DigestReply(bytes: 2_000_000), to: bob, now: 0)
        let answer = try #require(answers.answer(for: bob))
        #expect(!CustodyAnswers.isAged(answer, now: 119_999))
        #expect(CustodyAnswers.isAged(answer, now: 120_000))
        #expect(answers.nextDeadline == 120_000)
        answers.end(bob)
        #expect(answers.nextDeadline == nil)
        answers.noteArrived("a", from: bob)
        answers.released(CustodySync.DigestReply(), to: bob, now: 0)
        let waited = answers.wait(bob, until: 5)
        #expect(!waited)
        #expect(answers.all.isEmpty)
    }

    @Test func aWaitOnTheLineIsReportedFirstOnce() {
        var answers = CustodyAnswers()
        answers.receive([], from: bob, now: 0)
        let first = answers.wait(bob, until: 5000)
        let second = answers.wait(bob, until: 10_000)
        #expect(first)
        #expect(!second)
        #expect(answers.answer(for: bob)?.due == 10_000)
    }
}

/// The re-offer back-off (contract §7, revision 2), its worked cases on the 60 s tick.
@Suite struct ReofferBackoffTests: CustodySyncCase {
    /// The offers a neighbour that never draws gets on ticks every 60 s after a link-up at 0, through `until`.
    private func offers(through until: Int64, keptAt: Set<Int64> = []) -> [Int64] {
        var backoff = ReofferBackoff()
        backoff.linkedUp(bob, now: 0)
        var offered: [Int64] = [0]
        var tick: Int64 = 60_000
        while tick <= until {
            if keptAt.contains(tick - 20_000) {
                backoff.kept(from: bob)
            }
            if backoff.isDue(bob, now: tick) {
                backoff.offered(bob, now: tick)
                offered.append(tick)
            }
            tick += 60_000
        }
        return offered
    }

    @Test func aNeighbourThatNeverDrawsIsOfferedAtDoublingGaps() {
        let times = offers(through: 2_200_000)
        let gaps = zip(times.dropFirst(), times).map { ($0 - $1) / 1000 }
        #expect(gaps.prefix(6) == [60, 120, 240, 480, 600, 600])
    }

    @Test func aFrameKeptMidWaitBringsTheNextOfferAtTheNextTickAndAGapOfSixtyAfter() {
        // The 480 s wait starts at 420 s; a frame kept 100 s after it, at 520 s, offers at the 540 s tick, then 60 s on.
        var backoff = ReofferBackoff()
        backoff.linkedUp(bob, now: 0)
        for tick in [60_000, 180_000, 420_000] as [Int64] {
            #expect(backoff.isDue(bob, now: tick))
            backoff.offered(bob, now: tick)
        }
        #expect(backoff.pace(of: bob)?.interval == 480_000)
        #expect(!backoff.isDue(bob, now: 480_000))
        backoff.kept(from: bob)
        #expect(backoff.isDue(bob, now: 540_000))
        backoff.offered(bob, now: 540_000)
        #expect(backoff.pace(of: bob)?.interval == 60_000)
        #expect(backoff.isDue(bob, now: 600_000))
    }

    @Test func aTickTwentySecondsAfterTheLinkUpIsHeldAndOneFortyAfterOffers() {
        var backoff = ReofferBackoff()
        backoff.linkedUp(bob, now: 0)
        #expect(!backoff.isDue(bob, now: 20_000))
        #expect(backoff.isDue(bob, now: 40_000))
    }

    @Test func aTickAFewMillisecondsEarlyStillOffers() {
        #expect(ReofferBackoff.isDue(since: 0, interval: 60_000, now: 59_990))
        #expect(ReofferBackoff.isDue(since: 0, interval: 60_000, now: 30_000))
        #expect(!ReofferBackoff.isDue(since: 0, interval: 60_000, now: 29_999))
    }

    @Test func aRelinkResetsAndANeighbourWithNoPaceIsDue() {
        var backoff = ReofferBackoff()
        #expect(backoff.isDue(bob, now: 0))
        backoff.kept(from: bob)
        #expect(backoff.pace(of: bob) == nil)
        backoff.offered(bob, now: 0)
        #expect(backoff.pace(of: bob)?.interval == 60_000)
        backoff.offered(bob, now: 60_000)
        #expect(backoff.pace(of: bob)?.interval == 120_000)
        backoff.linkDown(bob)
        backoff.linkedUp(bob, now: 100_000)
        #expect(backoff.pace(of: bob) == ReofferBackoff.Pace(lastOffer: 100_000, interval: 60_000, drew: false))
    }
}

extension CarryLedger {
    /// Whether `peer` has a memo: a read of the ledger's state for the tests, kept out of `Sources` so the analyzer finds
    /// no declaration there that only tests call.
    func hasMemo(for peer: NodeId) -> Bool {
        memos[peer] != nil
    }
}
