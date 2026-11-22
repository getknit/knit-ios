import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The ledger, the memo and the back-off through the engine.
extension MeshEngineCustodyAnswerTests {
    // MARK: The ledger and the memo through the engine

    @Test func aProvenPeersDigestFeedsTheLedgerAndAnUnprovenOnesLeavesNothing() throws {
        let (fixture, ids) = try fixture(dms: 30)
        fixture.engine.receiveDigest(Array(ids.prefix(5)), from: bob.nodeId)
        #expect(fixture.engine.custody.ledger.holders(of: ids[0]) == [bob.nodeId])
        fixture.advance(Self.look)
        #expect(fixture.engine.custody.ledger.hasMemo(for: bob.nodeId), "pending from the credit")
        #expect(
            fixture.engine.custody.ledger.holders(of: ids[29]) == [bob.nodeId], "a hand-off credited at the next look, the link drained")

        fixture.transport.unproven = [carol.nodeId]
        fixture.link(carol)
        fixture.transport.clear()
        fixture.engine.receiveDigest(Array(ids.prefix(5)), from: carol.nodeId)
        #expect(!served(fixture, to: carol).isEmpty, "answered alike")
        for _ in 0..<20 {
            fixture.advance(Self.look)
        }
        #expect(served(fixture, to: carol).count == 25, "every frame its digest lacked")
        #expect(ids.allSatisfy { !fixture.engine.custody.ledger.holders(of: $0).contains(carol.nodeId) }, "no holder")
        #expect(!fixture.engine.custody.ledger.hasMemo(for: carol.nodeId), "no pending id and no mark")
        let wall = fixture.clock.wallMilliseconds()
        let relayed = try dave.directMessage("via carol", to: bob, id: frameIdOf("via-carol"), sentAt: wall)
        fixture.deliver(relayed, from: carol)
        #expect(fixture.stores.custody.contains(relayed.envelope.id))
        #expect(fixture.engine.custody.ledger.spread(of: relayed.envelope.id) == 0, "no source either")
    }

    @Test func aFrameNotKeptIsWithheldForTheLapseAndTheAskersOwnMailNeverIs() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(carol)
        fixture.link(bob)
        let wall = fixture.clock.wallMilliseconds()
        let theirs = try carol.directMessage("to dave", to: dave, id: frameIdOf("to-dave"), sentAt: wall)
        let mine = try carol.directMessage("to bob", to: bob, id: frameIdOf("to-bob"), sentAt: wall)
        for frame in [theirs, mine] {
            fixture.stores.custody.store(
                CarriedFrame(envelope: frame.envelope, sig: frame.wire.sig, signed: frame.wire.signed), origin: .relayed, now: wall)
        }
        let held = fixture.stores.custody.liveIds(now: wall).filter { $0 != theirs.envelope.id && $0 != mine.envelope.id }
        let both: Set<String> = [theirs.envelope.id, mine.envelope.id]
        fixture.transport.clear()
        fixture.engine.receiveDigest(held, from: bob.nodeId)
        #expect(Set(served(fixture, to: bob).map(\.envelope.id)) == both)
        // Bob kept neither: past the judging delay from the round's credit, at the next look, his next digest still lacks
        // both, and only the frame not addressed to him is marked, while his own mail goes again in the new answer.
        fixture.advance(Self.look)
        fixture.advance(CarryLedger.judgeAfterMilliseconds)
        fixture.transport.clear()
        fixture.engine.receiveDigest(held, from: bob.nodeId)
        #expect(fixture.engine.custodyRoundCounts.custodyNotKept == 1)
        #expect(served(fixture, to: bob).map(\.envelope.id) == [mine.envelope.id])
        // Inside the lapse a later answer still withholds it.
        fixture.advance(CustodyAnswers.maxAgeMilliseconds)
        fixture.transport.clear()
        fixture.engine.receiveDigest(held, from: bob.nodeId)
        #expect(served(fixture, to: bob).map(\.envelope.id) == [mine.envelope.id])
        #expect(fixture.engine.custodyRoundCounts.custodyNotKept == 1, "a later digest neither refreshes nor sets a mark")
        fixture.advance(CarryLedger.notKeptLapseMilliseconds)
        fixture.transport.clear()
        fixture.engine.receiveDigest(held, from: bob.nodeId)
        #expect(Set(served(fixture, to: bob).map(\.envelope.id)) == both, "past the lapse")
    }

    @Test func aPendingIdEndsUnjudgedTenMinutesAfterItsRelease() throws {
        let (fixture, ids) = try fixture(dms: 1)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(served(fixture, to: bob).map(\.envelope.id) == ids)
        fixture.advance(Self.look)
        let released = fixture.clock.monotonicMilliseconds()
        // No digest judges it for ten minutes.
        fixture.advance(CarryLedger.notKeptLapseMilliseconds - 1)
        #expect(
            fixture.engine.custody.ledger.withholds(
                ExactKey(ids[0]), from: bob.nodeId, now: released + CarryLedger.notKeptLapseMilliseconds - 1))
        fixture.advance(1)
        fixture.transport.clear()
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(served(fixture, to: bob).map(\.envelope.id) == ids, "released again, neither kept nor marked")
        #expect(fixture.engine.custodyRoundCounts.custodyNotKept == 0)
    }

    @Test func aLinkDownDropsThePeersMemo() throws {
        let (fixture, ids) = try fixture(dms: 1)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.unlink(bob)
        fixture.link(bob)
        fixture.transport.clear()
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(served(fixture, to: bob).map(\.envelope.id) == ids, "a release may have died with the link")
    }

    @Test func aKeyGoesAtMostOncePerAnswer() throws {
        // Carol's key is pinned here, and custody holds no profile of hers.
        let (fixture, ids) = try fixture(dms: 60)
        try fixture.pin(carol)
        let wall = fixture.clock.wallMilliseconds()
        let profiles = fixture.stores.custody.liveIndex(now: wall).filter { $0.type == .profile && $0.senderId == carol.nodeId.string }
        for entry in profiles {
            fixture.stores.custody.remove(entry.id)
        }
        fixture.transport.clear()
        fixture.engine.receiveDigest([], from: bob.nodeId)
        for _ in 0..<20 {
            fixture.advance(Self.look)
        }
        let keys = written(fixture, to: bob).filter { $0.envelope.type == .profile && $0.envelope.senderId == carol.nodeId.string }
        #expect(keys.count == 1, "\(keys.count) keys in \(fixture.engine.custodyRoundCounts.custodyRoundsCut) rounds")
        #expect(Set(served(fixture, to: bob).map(\.envelope.id)).isSuperset(of: ids))
    }

    @Test func aFailedReadFeedsAndPrunesNothing() throws {
        let failable = FailableStores()
        let failing = failable.custody
        let fixture = EngineFixture(alice, stores: failable.stores)
        try fixture.pin(carol)
        fixture.link(bob)
        let wall = fixture.clock.wallMilliseconds()
        let dm = try carol.directMessage("x", to: dave, id: frameIdOf("kept"), sentAt: wall)
        fixture.deliver(dm, from: bob)
        #expect(fixture.engine.custody.ledger.holders(of: dm.envelope.id) == [bob.nodeId], "its source")
        failing.failsReads = true
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) == nil, "a digest read against nothing is dropped")
        #expect(fixture.log.all.contains { $0.contains("mesh digest from \(bob.nodeId) dropped") })
        fixture.engine.pruneCarryLedger()
        // A held row that reads as absent is written again, and the store answers it held: its entries stay.
        let carried = CarriedFrame(envelope: dm.envelope, sig: dm.wire.sig, signed: dm.wire.signed)
        let again = fixture.engine.custody.carrying(carried, in: fixture.stores.custody, now: wall, from: carol.nodeId) { true }
        #expect(again == .alreadyHeld)
        failing.failsReads = false
        #expect(fixture.engine.custody.ledger.holders(of: dm.envelope.id) == [bob.nodeId], "a failed read wipes nothing")
        // An answer under way keeps the digest it had when a later one cannot be read.
        fixture.engine.receiveDigest([dm.envelope.id], from: bob.nodeId)
        failing.failsReads = true
        fixture.engine.receiveDigest([], from: bob.nodeId)
        failing.failsReads = false
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId)?.listed == [ExactKey(dm.envelope.id)])
    }

    @Test func aParkedFrameReplayedOnceItsKeyPinsCountsNoSource() throws {
        // A stranger's frame over a link claiming Carol, unproven, parks for want of Dave's key; Carol's id then proves
        // itself, and the key pins: the replay counts nobody, judged at its arrival, not now.
        let fixture = EngineFixture(alice)
        fixture.transport.unproven = [carol.nodeId]
        fixture.link(carol)
        let wall = fixture.clock.wallMilliseconds()
        let parked = try dave.directMessage("p", to: bob, id: frameIdOf("parked"), sentAt: wall)
        fixture.deliver(parked, from: carol)
        #expect(!fixture.stores.custody.contains(parked.envelope.id), "parked, not carried")
        fixture.transport.unproven = []
        fixture.engine.receiveDigest([], from: carol.nodeId)
        try fixture.pin(dave)
        #expect(fixture.stores.custody.contains(parked.envelope.id))
        #expect(fixture.engine.custody.ledger.spread(of: parked.envelope.id) == 0)
        #expect(fixture.engine.custodyAnswers.answer(for: carol.nodeId)?.arrivedSince.isEmpty == true)
        #expect(fixture.engine.reoffers.pace(of: carol.nodeId)?.drew == false)
    }

    @Test func anAnswerKeptOpenForHoursKeepsItsSetsWithinTheCapAndGoesOnlyAsTheLinkDrains() throws {
        // Bob's empty digest every minute keeps one answer open while Carol brings fresh mail twice a second, far past the
        // row cap, and the link writes 8,000 bytes a second: the answer's sets stay within the cap, and a round goes only
        // when the link holds less than one round unwritten.
        let limits = CustodyLimits(maxFrames: 50)
        let fixture = EngineFixture(alice, stores: .inMemory(custodyLimits: limits))
        try fixture.pin(carol)
        fixture.link(bob, carol)
        modelsDrain(fixture)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        var sent = fixture.engine.custodyRoundCounts.custodyRoundsCut
        for second in 0..<600 {
            let wall = fixture.clock.wallMilliseconds()
            for index in 0..<2 {
                let dm = try carol.directMessage("f", to: dave, id: frameIdOf("fresh-\(second)-\(index)"), sentAt: wall)
                fixture.deliver(dm, from: carol)
            }
            if second.isMultiple(of: 60), second > 0 {
                fixture.engine.receiveDigest([], from: bob.nodeId)
            }
            let unwritten = max(0, (fixture.transport.unwritten[bob.nodeId] ?? 0) - 8000)
            fixture.transport.unwritten[bob.nodeId] = unwritten
            fixture.advance(1000)
            let answer = try #require(fixture.engine.custodyAnswers.answer(for: bob.nodeId), "open at \(second) s")
            #expect(answer.released.count <= limits.maxFrames && answer.arrivedSince.count <= limits.maxFrames)
            #expect(answer.keysSent.count <= limits.maxFrames)
            let rounds = fixture.engine.custodyRoundCounts.custodyRoundsCut
            if rounds > sent {
                #expect(unwritten < CustodySync.roundBytes && rounds == sent + 1, "a round only on a drained link, at \(second) s")
                sent = rounds
            }
        }
        #expect(sent > 250, "\(sent) rounds")
    }

    @Test func aLedgerPastCustodysRowCapIsPrunedToTheLiveIds() throws {
        let fixture = EngineFixture(alice, stores: .inMemory(custodyLimits: CustodyLimits(maxFrames: 4)))
        let wall = fixture.clock.wallMilliseconds()
        // Stale entries, as units that rolled back would leave them.
        for index in 0..<5 {
            let stale = try carol.directMessage("s", to: dave, id: frameIdOf("stale-\(index)"), sentAt: wall)
            fixture.engine.custody.ledger.noteWrite(
                CustodyStoreResult(held: true, changed: true), of: stale.envelope, from: bob.nodeId, spreadMax: 8)
        }
        #expect(fixture.engine.custody.ledger.count == 5)
        fixture.advance(1)
        #expect(fixture.engine.custody.ledger.count < 1)
    }

    @Test func anIdThatLeftAndCameBackStartsWithNoHolder() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(carol)
        try fixture.pin(dave)
        fixture.link(bob, carol)
        let wall = fixture.clock.wallMilliseconds()
        let dm = try carol.directMessage("x", to: dave, id: frameIdOf("returns"), sentAt: wall)
        fixture.deliver(dm, from: bob)
        #expect(fixture.engine.custody.ledger.holders(of: dm.envelope.id) == [bob.nodeId])
        // A receipt from Dave purges it: its entry dies with the row.
        let receipt = try dave.receipt(for: dm.envelope.id, id: frameIdOf("receipt"), sentAt: wall)
        fixture.deliver(receipt, from: carol)
        #expect(!fixture.stores.custody.contains(dm.envelope.id))
        #expect(fixture.engine.custody.ledger.spread(of: dm.envelope.id) == 0)
        // Behind the feed's back, as a unit that rolled back would leave it, then written from Carol: its source alone.
        let late = try carol.directMessage("y", to: dave, id: frameIdOf("late"), sentAt: wall)
        fixture.engine.custody.ledger.noteWrite(
            CustodyStoreResult(held: true, changed: true), of: late.envelope, from: bob.nodeId, spreadMax: 8)
        #expect(!fixture.stores.custody.contains(late.envelope.id))
        fixture.deliver(late, from: carol)
        #expect(fixture.engine.custody.ledger.holders(of: late.envelope.id) == [carol.nodeId], "no holder inherited")
    }

    @Test func theStartClassifiesEveryGroupRowCustodyKept() throws {
        let stores = MeshStores.inMemory()
        let members = [carol, dave].map(\.nodeId.string)
        let group = GroupInfo(id: GroupId.derive(members), members: members, createdBy: carol.nodeId.string)
        let wall = EngineFixture.start
        let post = try carol.groupMessage("g", in: group, to: [dave], id: frameIdOf("kept-group"), sentAt: wall)
        stores.custody.store(
            CarriedFrame(envelope: post.envelope, sig: post.wire.sig, signed: post.wire.signed), origin: .relayed, now: wall)
        let fixture = EngineFixture(alice, stores: stores)
        #expect(fixture.engine.custody.ledger.roster(of: ExactKey(post.envelope.id))?.count == 2)
    }

    // MARK: The re-offer back-off

    @Test func onlyTheDigestIsHeldBackAndEachHoldIsCounted() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        // A frame from a sender whose key we lack: the re-offer asks for it on every tick.
        let wall = fixture.clock.wallMilliseconds()
        fixture.deliver(try carol.roomPost("who?", id: frameIdOf("unkeyed"), sentAt: wall), from: bob)
        fixture.advance(ReofferBackoff.baseMilliseconds)
        fixture.transport.clear()
        fixture.advance(ReofferBackoff.baseMilliseconds)
        #expect(fixture.transport.digests.isEmpty, "the digest is held")
        #expect(fixture.engine.custodyRoundCounts.custodyReoffersHeld == 1)
        #expect(fixture.transport.written.contains { $0.envelope.type == .keyRequest }, "the key ask still goes")
    }

    @Test func aFrameKeptFromANeighbourBringsItsNextOfferAtTheNextTick() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(carol)
        fixture.link(bob)
        for _ in 0..<4 {
            fixture.advance(ReofferBackoff.baseMilliseconds)
        }
        // Offered at 60 and 180 s; 240 s is held.
        #expect(fixture.transport.digests.count == 3)
        let wall = fixture.clock.wallMilliseconds()
        fixture.deliver(try carol.directMessage("x", to: dave, id: frameIdOf("drew"), sentAt: wall), from: bob)
        fixture.advance(ReofferBackoff.baseMilliseconds)
        #expect(fixture.transport.digests.count == 4)
        fixture.unlink(bob)
        fixture.link(bob)
        #expect(fixture.engine.reoffers.pace(of: bob.nodeId)?.interval == ReofferBackoff.baseMilliseconds, "a relink resets")
    }

    // MARK: A release is remembered only until a digest can speak to it (the contract, §2, revision 7)

    /// Alice's node with Carol and Dave pinned, linked to Bob, `target` in custody, then `seconds` of an answer to Bob kept
    /// open: Carol brings fresh mail each second and Bob sends a digest every 60 s, listing none of it. Answers when
    /// `target` was written to Bob by a round, in seconds from the first digest.
    private func keptOpen(_ fixture: EngineFixture, target: TestFrame, seconds: Int, each observe: ((Int) -> Void)? = nil) -> [Int] {
        let wall = fixture.clock.wallMilliseconds()
        fixture.stores.custody.store(
            CarriedFrame(envelope: target.envelope, sig: target.wire.sig, signed: target.wire.signed), origin: .relayed, now: wall)
        var times: [Int] = []
        var seen = fixture.transport.written.count
        for second in 0..<seconds {
            if second.isMultiple(of: 60) {
                fixture.engine.receiveDigest([], from: bob.nodeId)
            }
            let now = fixture.clock.wallMilliseconds()
            if let fresh = try? carol.directMessage("f", to: dave, id: frameIdOf("open-\(second)"), sentAt: now) {
                fixture.deliver(fresh, from: carol)
            }
            fixture.advance(1000)
            let written = fixture.transport.written.dropFirst(seen)
            seen = fixture.transport.written.count
            if written.contains(where: { $0.to == bob.nodeId && $0.wire.hops == 0 && $0.envelope.id == target.envelope.id }) {
                times.append(second)
            }
            #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) != nil, "the answer stays open at \(second) s")
            observe?(second)
        }
        return times
    }

    /// Whether `times` are a release at once and one in the rounds just after each of the digests at 60 and 120 s.
    private static func afterEachDigest(_ times: [Int]) -> Bool {
        times.count == 3 && times[0] == 0 && (60...65).contains(times[1]) && (120...126).contains(times[2])
    }

    /// A fixture for ``keptOpen(_:target:seconds:)``, Bob's link proven or not.
    private func openFixture(proven: Bool) throws -> EngineFixture {
        let fixture = EngineFixture(alice)
        try fixture.pin(carol)
        try fixture.pin(dave)
        if !proven {
            fixture.transport.unproven = [bob.nodeId]
        }
        fixture.link(bob, carol)
        return fixture
    }

    @Test func aFrameAddressedToThePeerGoesAgainOnceADigestCanSpeakToItsRelease() throws {
        let fixture = try openFixture(proven: true)
        let mail = try dave.directMessage("for bob", to: bob, id: frameIdOf("bobs-mail"), sentAt: fixture.clock.wallMilliseconds())
        let times = keptOpen(fixture, target: mail, seconds: 130)
        // Released at once; the digest at 60 s speaks to it and lacks it, so it goes again in the answer's next round, and
        // again after the one at 120 s.
        #expect(Self.afterEachDigest(times), "\(times)")
    }

    @Test func anyFrameOnAnUnprovenLinkGoesAgainOnceADigestCanSpeakToItsRelease() throws {
        let fixture = try openFixture(proven: false)
        let other = try dave.directMessage(
            "for zed", to: TestPeer(seed: 9), id: frameIdOf("others"), sentAt: fixture.clock.wallMilliseconds())
        let times = keptOpen(fixture, target: other, seconds: 130)
        #expect(Self.afterEachDigest(times), "no memo on an unproven link: \(times)")
    }

    @Test func aMarkedFrameOnAProvenLinkWaitsOutItsMarkThenGoesInTheSameAnswer() throws {
        let fixture = try openFixture(proven: true)
        let other = try dave.directMessage(
            "for zed", to: TestPeer(seed: 9), id: frameIdOf("marked"), sentAt: fixture.clock.wallMilliseconds())
        // The target itself, not another frame, is marked: withheld and no longer pending, from the 60 s digest to the lapse.
        let key = ExactKey(other.envelope.id)
        var marked: [Int] = []
        let times = keptOpen(fixture, target: other, seconds: 700) { second in
            let ledger = fixture.engine.custody.ledger
            let now = fixture.clock.monotonicMilliseconds()
            if ledger.withholds(key, from: bob.nodeId, now: now), !ledger.isPending(key, for: bob.nodeId, now: now) {
                marked.append(second)
            }
        }
        // Released at once and marked not kept by the digest at 60 s, which lacks it; the mark lapses ten minutes on and the
        // open answer, having forgotten the release, serves it in its next round.
        #expect(fixture.engine.custodyRoundCounts.custodyNotKept >= 1)
        #expect(marked.first == 60 && marked.count >= 590, "marked from \(marked.first ?? -1) s for \(marked.count) s")
        #expect(times.first == 0 && times.count == 2, "\(times)")
        #expect(times.last.map { (659...664).contains($0) } == true, "\(times)")
    }
}
