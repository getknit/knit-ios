import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A digest's paced answer, the carry ledger it feeds and the re-offer back-off, on one engine whose peers are played by
/// hand (the `custody-carry-policy` contract, §2, §3, §6 and §7).
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

    @Test func roundsGoAtTheLinksPaceAndANewerDigestDoesNotBringOneForward() throws {
        let (fixture, ids) = try fixture(dms: 120)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        let first = written(fixture, to: bob)
        #expect(!first.isEmpty && bytes(first) <= CustodySync.roundBytes, "\(bytes(first)) bytes")
        #expect(fixture.engine.custodyRoundCounts.custodyRoundsCut == 1)
        fixture.advance(1000)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(written(fixture, to: bob).count == first.count, "a newer digest brings no round forward")
        fixture.advance(999)
        #expect(written(fixture, to: bob).count == first.count)
        fixture.advance(1)
        #expect(written(fixture, to: bob).count > first.count, "the next round, one interval on")
        // Then every frame, once each, in rounds two seconds apart.
        for _ in 0..<40 {
            fixture.advance(CustodySync.roundMilliseconds)
        }
        let all = served(fixture, to: bob).map(\.envelope.id)
        #expect(Set(all) == Set(ids) && all.count == ids.count)
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) == nil, "the answer ended when nothing was left")
        #expect(fixture.engine.custodyRoundCounts.custodyAnswersCutShort == 0)
    }

    @Test func anAnswerCutByItsLinkIsCountedCutShort() throws {
        let (fixture, _) = try fixture(dms: 120)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.unlink(bob)
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) == nil)
        #expect(fixture.engine.custodyRoundCounts.custodyAnswersCutShort == 1)
        fixture.transport.clear()
        fixture.advance(CustodySync.roundMilliseconds)
        #expect(fixture.transport.written.isEmpty, "no round for a link that went")
    }

    @Test func anAnswerEndsTwoMinutesAfterItsLatestDigestAndIsCountedCutShort() throws {
        let (fixture, _) = try fixture(dms: 20)
        fixture.transport.unwritten[bob.nodeId] = HeldDigests.lineBytes
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
        fixture.advance(CustodySync.roundMilliseconds)
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
        fixture.advance(CustodySync.roundMilliseconds)
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) == nil)
        fixture.unlink(bob)
        #expect(fixture.engine.custodyRoundCounts.custodyAnswersCutShort == 0)
    }

    @Test func theLineDelaysARoundAndNeverEnlargesIt() throws {
        let (fixture, _) = try fixture(dms: 120)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        let first = written(fixture, to: bob).count
        fixture.transport.unwritten[bob.nodeId] = HeldDigests.lineBytes
        fixture.advance(CustodySync.roundMilliseconds)
        #expect(written(fixture, to: bob).count == first, "waits on the line")
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.advance(HeldDigests.recheckMilliseconds)
        let next = Array(written(fixture, to: bob).dropFirst(first))
        #expect(!next.isEmpty && bytes(next) <= CustodySync.roundBytes, "one round, cut fresh: \(bytes(next)) bytes")
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
            fixture.advance(CustodySync.roundMilliseconds)
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
        fixture.advance(CustodySync.roundMilliseconds)
        let next = served(fixture, to: bob).dropFirst(first).filter(\.wire.relay)
        #expect(next.first?.envelope.id == mail.envelope.id, "tier 2, cut fresh")
    }
}
