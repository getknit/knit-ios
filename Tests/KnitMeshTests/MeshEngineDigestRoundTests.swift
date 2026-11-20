import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// A digest's paced answer waits on its link, not on the peer (ADR 2026-10.f5zs, the `custody-carry-policy` contract, §2).
@Suite struct MeshEngineDigestRoundTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    /// Alice's node, linked to `peers`, with two posts of hers in custody beside her profile, and nothing written yet.
    private func fixture(_ peers: TestPeer...) throws -> (EngineFixture, [String]) {
        let fixture = EngineFixture(alice)
        for peer in peers {
            fixture.link(peer)
        }
        let first = try #require(fixture.engine.postToRoom("One"))
        let second = try #require(fixture.engine.postToRoom("Two"))
        fixture.transport.clear()
        return (fixture, [first.id, second.id])
    }

    private func served(_ fixture: EngineFixture, to peer: TestPeer) -> [String] {
        fixture.transport.written.filter { $0.to == peer.nodeId }.map(\.envelope.id)
    }

    @Test func aLinkBelowTheLineIsAnsweredAtOnce() throws {
        let (fixture, posts) = try fixture(bob)
        fixture.transport.unwritten[bob.nodeId] = HeldDigests.lineBytes - 1
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(Set(served(fixture, to: bob)).isSuperset(of: posts))
    }

    @Test func aRoundWaitsWhileTheLinkHoldsARoundAndGoesWithinFiveSecondsOfItFalling() throws {
        let (fixture, posts) = try fixture(bob)
        fixture.transport.unwritten[bob.nodeId] = HeldDigests.lineBytes
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(fixture.transport.written.isEmpty)
        #expect(fixture.engine.nextDeadline == fixture.clock.monotonicMilliseconds() + HeldDigests.recheckMilliseconds)
        fixture.advance(HeldDigests.recheckMilliseconds)
        #expect(fixture.transport.written.isEmpty, "still above the line, so it waits again")
        fixture.advance(1000)
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.advance(HeldDigests.recheckMilliseconds - 1001)
        #expect(fixture.transport.written.isEmpty)
        fixture.advance(1)
        #expect(Set(served(fixture, to: bob)).isSuperset(of: posts))
        fixture.transport.clear()
        fixture.advance(HeldDigests.recheckMilliseconds)
        #expect(fixture.transport.written.isEmpty, "answered once")
    }

    @Test func aNewerDigestReplacesTheHeldOne() throws {
        let (fixture, posts) = try fixture(bob)
        fixture.transport.unwritten[bob.nodeId] = HeldDigests.lineBytes
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.advance(1000)
        let held = fixture.stores.custody.liveIds(now: fixture.clock.wallMilliseconds()).filter { $0 != posts[1] }
        fixture.engine.receiveDigest(held, from: bob.nodeId)
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.advance(HeldDigests.recheckMilliseconds)
        #expect(served(fixture, to: bob) == [posts[1]], "one round, against the newer digest")
    }

    @Test func aNewerDigestDoesNotBringAWaitingRoundForward() throws {
        // A peer cannot raise the pace by sending digests: the answer takes the newer one and keeps its due time.
        let (fixture, posts) = try fixture(bob)
        fixture.transport.unwritten[bob.nodeId] = HeldDigests.lineBytes
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.advance(1000)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(fixture.transport.written.isEmpty, "the round waits for its look")
        fixture.advance(HeldDigests.recheckMilliseconds - 1000)
        #expect(Set(served(fixture, to: bob)).isSuperset(of: posts))
        fixture.transport.clear()
        fixture.advance(HeldDigests.recheckMilliseconds)
        #expect(fixture.transport.written.isEmpty, "nothing left to answer")
    }

    @Test func aHeldRoundLogsItsWaitOnce() throws {
        let (fixture, _) = try fixture(bob)
        fixture.transport.unwritten[bob.nodeId] = HeldDigests.lineBytes
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.advance(HeldDigests.recheckMilliseconds)
        fixture.advance(HeldDigests.recheckMilliseconds)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(fixture.log.all.filter { $0.contains("mesh digest from \(bob.nodeId) waits") }.count == 1)
        #expect(fixture.transport.written.isEmpty)
    }

    @Test func theLineIsALocalGuardOf128KiB() {
        #expect(HeldDigests.lineBytes == 131_072)
        #expect(HeldDigests.recheckMilliseconds == 5000)
    }

    @Test func aLinkGoingDropsItsHeldDigest() throws {
        let (fixture, _) = try fixture(bob, carol)
        fixture.transport.unwritten[bob.nodeId] = HeldDigests.lineBytes
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.unlink(bob)
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.advance(HeldDigests.recheckMilliseconds)
        #expect(fixture.transport.written.isEmpty)
    }

    @Test func oneLinkAboveTheLineHoldsOnlyItsOwnRound() throws {
        let (fixture, posts) = try fixture(bob, carol)
        fixture.transport.unwritten[bob.nodeId] = HeldDigests.lineBytes
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.engine.receiveDigest([], from: carol.nodeId)
        #expect(served(fixture, to: bob).isEmpty)
        #expect(Set(served(fixture, to: carol)).isSuperset(of: posts))
    }

    @Test func aRoundSendsEveryKeyAheadOfEveryFrame() throws {
        // Bob's pinned profile is the key; custody holds his posts but, past the quota, not his profile.
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        fixture.link(carol)
        let wall = fixture.clock.wallMilliseconds()
        let profileId = try #require(
            fixture.stores.custody.liveIndex(now: wall).first { $0.type == .profile && $0.senderId == bob.nodeId.string }?.id)
        fixture.stores.custody.remove(profileId)
        for index in 0..<3 {
            fixture.deliver(try bob.roomPost("Post \(index)", id: frameIdOf("bob-\(index)"), sentAt: wall), from: bob)
        }
        fixture.transport.clear()
        let ownProfile = fixture.stores.custody.liveIndex(now: wall).filter { $0.type == .profile }.map(\.id)
        fixture.engine.receiveDigest(ownProfile, from: carol.nodeId)
        let sent = fixture.transport.written.filter { $0.to == carol.nodeId }
        #expect(sent.first?.envelope.type == .profile)
        #expect(sent.first?.wire.relay == false, "the key goes point to point")
        #expect(sent.dropFirst().map(\.envelope.id).sorted() == (0..<3).map { frameIdOf("bob-\($0)") }.sorted())
    }
}
