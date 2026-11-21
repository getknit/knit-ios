import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A digest's answer released as the link drains, the carry ledger it feeds and the re-offer back-off, on one engine whose
/// peers are played by hand (the `custody-carry-policy` contract, §2, §3, §6 and §7, revision 13).
@Suite struct MeshEngineCustodyAnswerTests {
    let alice = TestPeer(seed: 1)
    let bob = TestPeer(seed: 2)
    let carol = TestPeer(seed: 3)
    let dave = TestPeer(seed: 4)

    /// Alice's node linked to Bob, its custody holding `count` DMs from Carol to Dave with `payload` bytes of body each,
    /// stored behind the engine's back, and nothing written yet.
    func fixture(dms count: Int, body: Int = 600) throws -> (EngineFixture, [String]) {
        let fixture = EngineFixture(alice)
        try fixture.pin(carol)
        try fixture.pin(dave)
        fixture.link(bob)
        let wall = fixture.clock.wallMilliseconds()
        var ids: [String] = []
        for index in 0..<count {
            let dm = try carol.directMessage(
                String(repeating: "x", count: body), to: dave, id: frameIdOf("dm-\(index)"), sentAt: wall - 1000 + Int64(index))
            fixture.stores.custody.store(
                CarriedFrame(envelope: dm.envelope, sig: dm.wire.sig, signed: dm.wire.signed), origin: .relayed, now: wall)
            ids.append(dm.envelope.id)
        }
        fixture.transport.clear()
        return (fixture, ids)
    }

    /// The chats written to `peer`: what the rounds served of the DMs, the profiles in custody left out.
    func served(_ fixture: EngineFixture, to peer: TestPeer) -> [Written] {
        fixture.transport.written.filter { $0.to == peer.nodeId && $0.envelope.type == .chat }
    }

    /// What the rounds wrote to `peer`: the frames custody holds, fresh, and the keys ahead of them, the router's relays and
    /// a link-up's other pushes left out.
    func written(_ fixture: EngineFixture, to peer: TestPeer) -> [Written] {
        fixture.transport.written.filter { written in
            written.to == peer.nodeId && written.wire.hops == 0
                && (fixture.stores.custody.contains(written.envelope.id) || (written.envelope.type == .profile && !written.wire.relay))
        }
    }

    func bytes(_ written: [Written]) -> Int {
        written.reduce(0) { $0 + $1.wire.encoded.count }
    }

    /// One look.
    static let look = CustodyAnswers.roundCheckMilliseconds

    /// Has the transport count what the engine writes to Bob as unwritten until a test drains it: the link as the engine sees
    /// it, through `queuedBytes(to:)`.
    func modelsDrain(_ fixture: EngineFixture) {
        let transport = fixture.transport
        let peer = bob.nodeId
        transport.onWrite = { [weak transport] written in
            if written.to == peer {
                transport?.unwritten[peer, default: 0] += written.wire.encoded.count
            }
        }
    }

    /// How many rounds the engine cut so far.
    func roundCount(_ fixture: EngineFixture) -> Int {
        fixture.engine.custodyRoundCounts.custodyRoundsCut
    }

    @Test func aDrainedLinkGetsItsNextRoundAtTheNextLook() throws {
        let (fixture, _) = try fixture(dms: 120)
        modelsDrain(fixture)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        let first = written(fixture, to: bob)
        #expect(!first.isEmpty && bytes(first) <= CustodySync.roundBytes, "\(bytes(first)) bytes")
        #expect(roundCount(fixture) == 1, "the first round when the digest arrives")
        fixture.transport.unwritten[bob.nodeId] = CustodySync.roundBytes
        for _ in 0..<5 {
            fixture.advance(Self.look)
        }
        #expect(roundCount(fixture) == 1, "a round unwritten holds the next")
        fixture.transport.unwritten[bob.nodeId] = CustodySync.roundBytes - 1
        fixture.advance(Self.look)
        #expect(roundCount(fixture) == 2, "under one round unwritten: the next, at the next look")
    }

    @Test func aLinkThatDoesNotDrainGetsNoSecondRound() throws {
        let (fixture, _) = try fixture(dms: 120)
        modelsDrain(fixture)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.transport.unwritten[bob.nodeId] = max(fixture.transport.unwritten[bob.nodeId] ?? 0, CustodySync.roundBytes)
        fixture.advance(60_000)
        #expect(roundCount(fixture) == 1)
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) != nil, "the answer waits, open")
    }

    @Test func aLinkIsNeverHandedMoreThanUnderTwoRoundsPlusAFirstPick() throws {
        // The link takes 1,000 bytes a look; the engine cuts as it drains, and what waits unwritten never reaches two rounds.
        let (fixture, ids) = try fixture(dms: 120)
        modelsDrain(fixture)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        var most = fixture.transport.unwritten[bob.nodeId] ?? 0
        let largest = written(fixture, to: bob).map(\.wire.encoded.count).max() ?? 0
        for _ in 0..<2000 {
            fixture.transport.unwritten[bob.nodeId] = max(0, (fixture.transport.unwritten[bob.nodeId] ?? 0) - 1000)
            fixture.advance(Self.look)
            most = max(most, fixture.transport.unwritten[bob.nodeId] ?? 0)
        }
        #expect(most < 2 * CustodySync.roundBytes + largest, "\(most) bytes unwritten at most")
        #expect(Set(served(fixture, to: bob).map(\.envelope.id)) == Set(ids), "and every frame went, once each")
        #expect(served(fixture, to: bob).count == ids.count)
    }

    @Test func aFirstPickOverTheBudgetHoldsTheNextRoundUntilTheLinkDrains() throws {
        let (fixture, _) = try fixture(dms: 3, body: 20_000)
        // The profiles would go first, in a round of their own.
        let wall = fixture.clock.wallMilliseconds()
        for entry in fixture.stores.custody.liveIndex(now: wall) where entry.type == .profile {
            fixture.stores.custody.remove(entry.id)
        }
        modelsDrain(fixture)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        let first = written(fixture, to: bob)
        #expect(
            served(fixture, to: bob).count == 1 && bytes(first) > CustodySync.roundBytes, "one frame past the budget: \(bytes(first)) bytes"
        )
        fixture.transport.unwritten[bob.nodeId] = CustodySync.roundBytes
        fixture.advance(Self.look)
        #expect(roundCount(fixture) == 1, "drained to a round, not under it")
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.advance(Self.look)
        #expect(roundCount(fixture) == 2)
    }

    @Test func aFileStreamingDoesNotHoldAnAnswerOff() throws {
        // The link holds a streaming file's window, which the one comparison leaves out (`queuedFrameBytes(to:)`, the
        // contract, §2, "Unwritten").
        let (fixture, _) = try fixture(dms: 120)
        modelsDrain(fixture)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.transport.unwritten[bob.nodeId] = 60_000
        fixture.transport.fileWindow[bob.nodeId] = 60_000
        fixture.advance(Self.look)
        #expect(roundCount(fixture) == 2, "a link holding only a file's window takes the next round")
        // Without the window counted out it would have waited: the same bytes, all frames, hold it.
        fixture.transport.unwritten[bob.nodeId] = 60_000
        fixture.transport.fileWindow[bob.nodeId] = 0
        fixture.advance(Self.look)
        #expect(roundCount(fixture) == 2)
    }

    @Test func aHandOffIsCreditedAtTheDrainedLookAndTheLastOneAfterTheAnswerEnded() throws {
        let (fixture, ids) = try fixture(dms: 3)
        modelsDrain(fixture)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(served(fixture, to: bob).count == 3, "one round served all there was")
        fixture.transport.unwritten[bob.nodeId] = CustodySync.roundBytes
        fixture.advance(Self.look)
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) == nil, "nothing left: the answer ended, undrained")
        #expect(ids.allSatisfy { fixture.engine.custody.ledger.spread(of: $0) == 0 }, "not credited before the drain")
        #expect(fixture.engine.nextDeadline == fixture.clock.monotonicMilliseconds() + Self.look, "the credit keeps the look")
        fixture.advance(Self.look)
        #expect(ids.allSatisfy { fixture.engine.custody.ledger.spread(of: $0) == 0 }, "still undrained")
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.advance(Self.look)
        #expect(ids.allSatisfy { fixture.engine.custody.ledger.holders(of: $0) == [bob.nodeId] }, "credited at the drained look")
        #expect(fixture.engine.custody.ledger.creditsWaiting.isEmpty)
    }

    @Test func aNewerDigestCutsNoRound() throws {
        let (fixture, _) = try fixture(dms: 120)
        modelsDrain(fixture)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(roundCount(fixture) == 1, "digests to an open answer cut nothing, drained or not")
        fixture.advance(Self.look)
        #expect(roundCount(fixture) == 2, "the look does")
    }

    @Test func anAnswerCutByItsLinkIsCountedCutShort() throws {
        let (fixture, _) = try fixture(dms: 120)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.unlink(bob)
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) == nil)
        #expect(fixture.engine.custodyRoundCounts.custodyAnswersCutShort == 1)
        fixture.transport.clear()
        fixture.advance(Self.look)
        #expect(fixture.transport.written.isEmpty, "no round for a link that went")
    }

    @Test func anAnswerEndsTwoMinutesAfterItsLatestDigestAndIsCountedCutShort() throws {
        let (fixture, _) = try fixture(dms: 20)
        fixture.transport.unwritten[bob.nodeId] = CustodySync.roundBytes
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.advance(CustodyAnswers.maxAgeMilliseconds - 1)
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) != nil)
        fixture.advance(1)
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) == nil)
        #expect(fixture.engine.custodyRoundCounts.custodyAnswersCutShort == 1)
        #expect(written(fixture, to: bob).isEmpty)
        #expect(fixture.log.all.filter { $0.contains("mesh digest from \(bob.nodeId) waits") }.count == 1, "the wait logged once")
    }

    @Test func aRoundDueOnALinkTheTransportNoLongerHoldsEndsItsAnswer() throws {
        let (fixture, _) = try fixture(dms: 120)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.transport.neighbors.removeAll()
        fixture.transport.clear()
        fixture.advance(Self.look)
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) == nil)
        #expect(written(fixture, to: bob).isEmpty)
    }

    @Test func aRoundForAPeerWithNoAnswerSendsNothing() throws {
        let (fixture, _) = try fixture(dms: 5)
        fixture.engine.serveCustodyRound(to: bob.nodeId, now: fixture.clock.monotonicMilliseconds())
        #expect(written(fixture, to: bob).isEmpty && fixture.engine.custodyRoundCounts.custodyRoundsCut == 0)
    }

    @Test func anAnswerThatRanOutIsNotCountedCutShortWhenItsLinkGoes() throws {
        let (fixture, _) = try fixture(dms: 2)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.advance(Self.look)
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) == nil)
        fixture.unlink(bob)
        #expect(fixture.engine.custodyRoundCounts.custodyAnswersCutShort == 0)
    }

    @Test func anAnswerKeepsOnlyTheDigestsIdsWeHold() throws {
        let (fixture, ids) = try fixture(dms: 10)
        let junk = (0..<14_000).map { frameIdOf("junk-\($0)") }
        fixture.engine.receiveDigest(junk + Array(ids.prefix(3)), from: bob.nodeId)
        let live = fixture.stores.custody.liveIds(now: fixture.clock.wallMilliseconds()).count
        let answer = try #require(fixture.engine.custodyAnswers.answer(for: bob.nodeId))
        #expect(answer.listed.count == 3 && answer.listed.count <= live)
    }

    @Test func aFrameThatArrivedFromThePeerSinceItsDigestIsNotServedBack() throws {
        let (fixture, _) = try fixture(dms: 60)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        let wall = fixture.clock.wallMilliseconds()
        let fresh = try carol.directMessage("new", to: dave, id: frameIdOf("fresh"), sentAt: wall)
        fixture.deliver(fresh, from: bob)
        #expect(fixture.stores.custody.contains(fresh.envelope.id))
        for _ in 0..<20 {
            fixture.advance(Self.look)
        }
        #expect(!served(fixture, to: bob).contains { $0.envelope.id == fresh.envelope.id })
    }

    @Test func aDMThatArrivesMidAnswerGoesInTheNextRoundAheadOfTheRest() throws {
        let (fixture, _) = try fixture(dms: 120)
        fixture.link(carol)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        let first = served(fixture, to: bob).count
        let wall = fixture.clock.wallMilliseconds()
        let mail = try carol.directMessage("for bob", to: bob, id: frameIdOf("for-bob"), sentAt: wall)
        fixture.deliver(mail, from: carol)
        fixture.advance(Self.look)
        let next = served(fixture, to: bob).dropFirst(first).filter(\.wire.relay)
        #expect(next.first?.envelope.id == mail.envelope.id, "tier 2, cut fresh")
    }
}
