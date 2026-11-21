import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A digest's answer waits on its link, not on the peer: each next round goes once the link drains under one round (ADR
/// 2026-10.f5zs, the `custody-carry-policy` contract, §2, revision 13).
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

    /// A round's bytes: what the link holds unwritten until it drains.
    private static let round = CustodySync.roundBytes
    /// One look.
    private static let look = CustodyAnswers.roundCheckMilliseconds

    @Test func aLinkUnderOneRoundIsAnsweredAtOnce() throws {
        let (fixture, posts) = try fixture(bob)
        fixture.transport.unwritten[bob.nodeId] = Self.round - 1
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(Set(served(fixture, to: bob)).isSuperset(of: posts))
    }

    @Test func aRoundWaitsWhileTheLinkHoldsARoundAndGoesAtTheFirstLookAfterItDrains() throws {
        let (fixture, posts) = try fixture(bob)
        fixture.transport.unwritten[bob.nodeId] = Self.round
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(fixture.transport.written.isEmpty)
        #expect(fixture.engine.nextDeadline == fixture.clock.monotonicMilliseconds() + Self.look)
        fixture.advance(Self.look)
        #expect(fixture.transport.written.isEmpty, "still a round unwritten, so it waits again")
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.advance(Self.look - 1)
        #expect(fixture.transport.written.isEmpty, "no look yet")
        fixture.advance(1)
        #expect(Set(served(fixture, to: bob)).isSuperset(of: posts))
        fixture.transport.clear()
        fixture.advance(Self.look)
        #expect(fixture.transport.written.isEmpty, "answered once")
    }

    @Test func aNewerDigestReplacesTheOneTheRoundsAreCutFrom() throws {
        let (fixture, posts) = try fixture(bob)
        fixture.transport.unwritten[bob.nodeId] = Self.round
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.advance(1000)
        let held = fixture.stores.custody.liveIds(now: fixture.clock.wallMilliseconds()).filter { $0 != posts[1] }
        fixture.engine.receiveDigest(held, from: bob.nodeId)
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.advance(Self.look)
        #expect(served(fixture, to: bob) == [posts[1]], "one round, against the newer digest")
    }

    @Test func aNewerDigestCutsNoRoundOfItsOwn() throws {
        // A peer cannot draw rounds by sending digests: the answer takes the newer one and waits for its next look.
        let (fixture, posts) = try fixture(bob)
        fixture.transport.unwritten[bob.nodeId] = Self.round
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.advance(Self.look / 2)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(fixture.transport.written.isEmpty, "the round waits for its look")
        fixture.advance(Self.look / 2)
        #expect(Set(served(fixture, to: bob)).isSuperset(of: posts))
        fixture.transport.clear()
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(fixture.transport.written.isEmpty, "a digest to an open answer cuts nothing")
        fixture.advance(Self.look)
        #expect(fixture.transport.written.isEmpty, "nothing left to answer")
    }

    @Test func aRoundWaitingOnTheDrainLogsItsWaitOnce() throws {
        let (fixture, _) = try fixture(bob)
        fixture.transport.unwritten[bob.nodeId] = Self.round
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        for _ in 0..<20 {
            fixture.advance(Self.look)
        }
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(fixture.log.all.filter { $0.contains("mesh digest from \(bob.nodeId) waits") }.count == 1)
        #expect(fixture.transport.written.isEmpty)
    }

    @Test func nothingIsDueWhenNoAnswerIsOpenAndNoHandOffWaits() throws {
        let (fixture, _) = try fixture(bob)
        let before = fixture.engine.nextDeadline ?? .max
        #expect(before > fixture.clock.monotonicMilliseconds() + Self.look, "no look without an answer")
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(fixture.engine.nextDeadline == fixture.clock.monotonicMilliseconds() + Self.look)
        // The round the digest cut leaves a hand-off waiting, credited at the next look, and the answer ends there.
        fixture.advance(Self.look)
        #expect((fixture.engine.nextDeadline ?? .max) > fixture.clock.monotonicMilliseconds() + Self.look)
    }

    @Test func aLinkGoingDropsItsAnswer() throws {
        let (fixture, _) = try fixture(bob, carol)
        fixture.transport.unwritten[bob.nodeId] = Self.round
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.unlink(bob)
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.advance(Self.look)
        #expect(fixture.transport.written.isEmpty)
    }

    @Test func oneLinkThatHasNotDrainedHoldsOnlyItsOwnRound() throws {
        let (fixture, posts) = try fixture(bob, carol)
        fixture.transport.unwritten[bob.nodeId] = Self.round
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
