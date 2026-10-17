import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The send side of knit-next's group labs, as iPhones on links with the switch on (ADR 2026-10.5sk9, phase P6b):
/// `GroupMembershipLabTest`'s leave rekey, rejoin and #167 cases, and `GroupFirstMessageLabTest`'s first messages, now that
/// an iPhone seals the group form (at knit-next `cbf2a487`). Every node is an engine of this port, and the lab's holds
/// stand in for Kotlin's `transport.hold` and `release`.
@Suite struct GroupSendLabTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 5)
    private let carol = TestPeer(seed: 6)
    private var hop: Int64 { Router.Configuration().jitterWindowMilliseconds + 1 }

    /// iPhones for `peers` with the switch on, linked as `links` says and acquainted, each pinning the others' profiles.
    private func lab(_ peers: [TestPeer], links: [(Int, Int)]) throws -> EngineLab {
        let lab = EngineLab(try peers.enumerated().map { index, peer in try EngineFixture.ratcheting(peer, seed: UInt64(31 + index)) })
        for (first, second) in links {
            lab.link(first, second)
        }
        settle(lab)
        return lab
    }

    /// Lets every flood cross the lab: a hop for each node it may have to cross.
    private func settle(_ lab: EngineLab) {
        for _ in 0..<3 {
            lab.advance(hop)
        }
    }

    /// The bodies of node `index`'s ordinary messages in `group`.
    private func bodies(_ lab: EngineLab, _ index: Int, in group: String) -> Set<String> {
        Set(lab[index].stores.messages.messages(in: group).filter { $0.kind == .message }.map(\.body))
    }

    /// Node `index` sends `text` to `group`, and the floods cross the lab.
    private func send(_ lab: EngineLab, _ index: Int, _ text: String, to group: String) throws {
        _ = try #require(lab[index].engine.sendGroupMessage(text, to: group))
        settle(lab)
    }

    private func isGroupFrame(_ item: EngineLab.Carried) -> Bool {
        guard case .frame(let written) = item else {
            return false
        }
        return written.envelope.group != nil
    }

    /// Whether `item` is a DM-form chat from node `from`'s peer to node `to`'s.
    private func isDirect(_ item: EngineLab.Carried, from: TestPeer, to: TestPeer) -> Bool {
        guard case .frame(let written) = item else {
            return false
        }
        return written.envelope.senderId == from.nodeId.string && written.envelope.recipientId == to.nodeId.string
    }

    /// Kotlin's `leaveRekeysTheRemainderAndTheLeaverReadsNothingMore`: Carol leaves; Bob's next message mints an epoch past
    /// the retired one, whose seed goes to Alice alone, and the three ends converge on it.
    @Test func leaveRekeysTheRemainderAndTheLeaverReadsNothingMore() throws {
        let lab = try lab([alice, bob, carol], links: [(0, 1), (1, 2), (0, 2)])
        let group = try #require(lab[0].engine.createGroup(with: [bob.nodeId, carol.nodeId])).id
        try send(lab, 0, "founded", to: group)
        #expect((0...2).allSatisfy { bodies(lab, $0, in: group) == ["founded"] })
        try send(lab, 1, "bob's first", to: group)
        let seedsBefore = lab[1].engine.groupCounts.groupSeedsSent
        let toCarol = lab[1].chats(to: carol).count
        #expect(lab[2].engine.leaveGroup(group))
        settle(lab)
        #expect(lab[1].stores.groups.group(group)?.departed == [carol.nodeId.string])
        #expect(lab[1].stores.groupRatchet.sendChains(group).isEmpty, "the leave retired Bob's chain")
        try send(lab, 1, "after carol left", to: group)
        #expect(lab[1].engine.groupCounts.groupSeedsSent == seedsBefore + 1, "a fresh seed, to Alice alone")
        #expect(lab[1].chats(to: carol).count == toCarol && lab[1].stores.groupRatchet.keySend(group, member: carol.nodeId) == nil)
        #expect(lab[1].stores.groupRatchet.sendChains(group).first?.epoch == 2, "numbered past the retired epoch")
        #expect(bodies(lab, 0, in: group) == ["founded", "bob's first", "after carol left"])
        #expect(lab[2].stores.groups.group(group)?.hasLeft == true && bodies(lab, 2, in: group).isEmpty, "Carol reads nothing more")
        #expect(lab[2].stores.groupRatchet.holdings(of: group).recvChains.isEmpty, "her group state went with the leave")
        lab.advance(MeshConfiguration().reofferMilliseconds)
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)) && Set(lab.liveIds(1)) == Set(lab.liveIds(2)))
    }

    /// Kotlin's `aRejoinersSeedThatOutrunsTheRejoinFrameRejoinsThemItself`: Alice leaves and puts the same two together again;
    /// her new epoch's seed reaches Bob ahead of her frame, carries the founding roster, and rejoins her itself.
    @Test func aRejoinersSeedThatOutrunsTheRejoinFrameRejoinsThemItself() throws {
        let lab = try lab([alice, bob], links: [(0, 1)])
        let group = try #require(lab[0].engine.createGroup(with: [bob.nodeId])).id
        try send(lab, 0, "founded", to: group)
        #expect(lab[0].engine.leaveGroup(group))
        settle(lab)
        #expect(lab[1].stores.groups.group(group)?.departed == [alice.nodeId.string])
        lab.hold(from: 0, to: 1)
        #expect(lab[0].engine.createGroup(with: [bob.nodeId])?.id == group, "the same people are the same group")
        try send(lab, 0, "i am back", to: group)
        #expect(lab[0].stores.groupRatchet.sendChains(group).first?.epoch == 2, "past the epoch the leave retired")
        lab.release(from: 0, to: 1) { $0.filter { !isGroupFrame($0) } }
        #expect(lab[1].stores.groups.group(group)?.departed.isEmpty == true, "her own seed rejoined her")
        #expect(lab[1].engine.groupCounts.groupSeedsHeld == 0)
        lab.unlink(0, 1)
        lab.link(0, 1)
        settle(lab)
        #expect(bodies(lab, 1, in: group) == ["founded", "i am back"], "back-filled, opened on its first pass")
        #expect(bodies(lab, 0, in: group) == ["i am back"], "Alice's thread starts again")
    }

    /// Kotlin's `aLeaveRekeysSeedThatOvertakesTheEarlierOneLosesNothing` (#167, knit-next ADR 2026-10.xgwj): Carol posts, Alice
    /// leaves, Carol posts again under a fresh epoch, and Bob, behind a held link, meets the second seed first. The retired
    /// chain kept its number, so the re-mint is epoch 2, which Bob adopts beside epoch 1 in either order.
    @Test func aLeaveRekeysSeedThatOvertakesTheEarlierOneLosesNothing() throws {
        let lab = try lab([alice, carol, bob], links: [(0, 1), (1, 2)])
        let group = try #require(lab[0].engine.createGroup(with: [bob.nodeId, carol.nodeId])).id
        try send(lab, 0, "founded", to: group)
        #expect((0...2).allSatisfy { bodies(lab, $0, in: group) == ["founded"] })
        let seedsBefore = lab[1].engine.groupCounts.groupSeedsSent
        lab.hold(from: 1, to: 2)
        try send(lab, 1, "before the leave", to: group)
        #expect(lab[0].engine.leaveGroup(group))
        settle(lab)
        #expect(lab[1].stores.groups.group(group)?.departed == [alice.nodeId.string])
        try send(lab, 1, "after the leave", to: group)
        #expect(lab[1].engine.groupCounts.groupSeedsSent >= seedsBefore + 3, "one seed each to Alice and Bob, then one to Bob")
        lab.release(from: 1, to: 2) { batch in
            let toBob = batch.filter { isDirect($0, from: carol, to: bob) }
            return toBob.reversed() + batch.filter { !isDirect($0, from: carol, to: bob) }
        }
        settle(lab)
        #expect(bodies(lab, 2, in: group) == ["founded", "before the leave", "after the leave"])
        #expect(lab[2].engine.dropped[.groupRatchetAeadFail] == nil, "no seed was lost as stale")
        #expect(lab[2].stores.groups.group(group)?.departed == [alice.nodeId.string])
    }

    /// Kotlin's `aRecreatedGroupsSeedThatOvertakesThePreLeaveOneLosesNothing` (#167's local half): Alice posts, leaves, puts the
    /// same people together again and posts once more; Carol hears the second post's seed first. The leave's purge kept the
    /// number, so the re-mint is the next epoch, and the post sealed before the leave still opens.
    @Test func aRecreatedGroupsSeedThatOvertakesThePreLeaveOneLosesNothing() throws {
        let lab = try lab([bob, alice, carol], links: [(0, 1), (1, 2)])
        let group = try #require(lab[0].engine.createGroup(with: [alice.nodeId, carol.nodeId])).id
        try send(lab, 0, "founded", to: group)
        #expect((0...2).allSatisfy { bodies(lab, $0, in: group) == ["founded"] })
        let seedsBefore = lab[1].engine.groupCounts.groupSeedsSent
        lab.hold(from: 1, to: 2)
        try send(lab, 1, "before the leave", to: group)
        #expect(lab[1].engine.leaveGroup(group))
        settle(lab)
        #expect(lab[0].stores.groups.group(group)?.departed == [alice.nodeId.string])
        #expect(lab[1].engine.createGroup(with: [bob.nodeId, carol.nodeId])?.id == group)
        try send(lab, 1, "back again", to: group)
        #expect(lab[1].engine.groupCounts.groupSeedsSent >= seedsBefore + 4, "one seed each to Bob and Carol, both times")
        #expect(lab[1].stores.groupRatchet.sendChains(group).first?.epoch == 2, "the purge kept the number")
        lab.release(from: 1, to: 2) { batch in
            let toCarol = batch.filter { isDirect($0, from: alice, to: carol) }
            return toCarol.reversed() + batch.filter { !isDirect($0, from: alice, to: carol) }
        }
        settle(lab)
        #expect(bodies(lab, 2, in: group) == ["founded", "before the leave", "back again"])
        #expect(lab[2].engine.dropped[.groupRatchetAeadFail] == nil, "no seed was lost as stale")
        #expect(lab[2].stores.groups.group(group)?.departed.isEmpty == true)
    }

    /// Kotlin's `firstGroupMessageLandsWhenTheSeedOutrunsTheRoster`, an iPhone the author: the seed, carrying the founding
    /// roster, lands first and pins the group, so the frame opens on its first pass.
    @Test func firstGroupMessageLandsWhenTheSeedOutrunsTheRoster() throws {
        let lab = try lab([alice, bob], links: [(0, 1)])
        lab.hold(from: 0, to: 1)
        let group = try #require(lab[0].engine.createGroup(with: [bob.nodeId])).id
        try send(lab, 0, "welcome", to: group)
        lab.release(from: 0, to: 1) { $0.filter { !isGroupFrame($0) } + $0.filter(isGroupFrame) }
        #expect(bodies(lab, 1, in: group) == ["welcome"])
        #expect(lab[1].engine.dropped[.groupRatchetNoKey] == nil && lab[1].engine.groupCounts.groupSeedsHeld == 0)
    }

    /// Kotlin's `firstGroupMessageLandsWhenTheRosterOutrunsTheSeed`, an iPhone the author: the frame lands first and makes
    /// the group, fails as `NO_KEY` and stays in custody, and the seed's adoption opens it from there.
    @Test func firstGroupMessageLandsWhenTheRosterOutrunsTheSeed() throws {
        let lab = try lab([alice, bob], links: [(0, 1)])
        lab.hold(from: 0, to: 1)
        let group = try #require(lab[0].engine.createGroup(with: [bob.nodeId])).id
        try send(lab, 0, "welcome", to: group)
        lab.release(from: 0, to: 1) { $0.filter(isGroupFrame) + $0.filter { !isGroupFrame($0) } }
        #expect(bodies(lab, 1, in: group) == ["welcome"])
        #expect(lab[1].engine.dropped[.groupRatchetNoKey] == 1, "keyless first, then the instant replay")
        lab.advance(MeshConfiguration().reofferMilliseconds)
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)))
    }

    /// Kotlin's `firstGroupMessageLandsAcrossARelay`, an iPhone the author: Carol, outside the group and without the switch,
    /// carries the seed and the frame from Alice to Bob.
    @Test func firstGroupMessageLandsAcrossARelay() throws {
        let lab = EngineLab([
            try EngineFixture.ratcheting(alice, seed: 41), EngineFixture(carol, seed: 42), try EngineFixture.ratcheting(bob, seed: 43),
        ])
        lab.link(0, 1)
        lab.link(1, 2)
        settle(lab)
        let group = try #require(lab[0].engine.createGroup(with: [bob.nodeId])).id
        try send(lab, 0, "across", to: group)
        #expect(bodies(lab, 2, in: group) == ["across"], "across the relay")
        #expect(lab[1].stores.messages.messages(in: group).isEmpty, "the carrier holds no thread")
        // Bob's sealed tick goes once its batch's debounce runs out; two exchanges carry it everywhere.
        lab.advance(MeshConfiguration().reofferMilliseconds)
        settle(lab)
        lab.advance(MeshConfiguration().reofferMilliseconds)
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)) && Set(lab.liveIds(1)) == Set(lab.liveIds(2)))
    }
}
