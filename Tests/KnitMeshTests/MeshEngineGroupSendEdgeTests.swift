import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// This port's own cases of the group form's send side (ADR 2026-10.5sk9, phase P6b): a message that waited for every key
/// and goes in the group form once one pins, a reaction with no group to seal to, one whose unit fails or joins another, a
/// group seal whose own write fails, and a re-send to a member nothing can be sealed to.
@Suite struct MeshEngineGroupSendEdgeTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private var now: Int64 { EngineFixture.start }

    @Test func aMessageThatWaitedForEveryKeyGoesInTheGroupFormOnceTheMemberPins() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let group = fixture.holdGroup(with: [alice])
        let message = try #require(fixture.engine.sendGroupMessage("waiting", to: group.id))
        #expect(message.pendingKey && fixture.transport.written(.chat).isEmpty, "nobody to wrap to: it waits")
        let reader = GroupFormReader(try AndroidPeer(alice))
        try fixture.pin(reader.android)
        #expect(fixture.stores.messages.message(message.id)?.pendingKey == false)
        let frame = try #require(fixture.groupFrames(in: group.id).first)
        try reader.receive(try #require(fixture.chats(to: alice).first), from: me)
        #expect(reader.body(of: frame, from: me) == "waiting", "the flush on her profile sealed it in the group form")
        #expect(fixture.chats(to: alice).count == 1, "the profile's seed flush found nothing owed yet, so one seed")
    }

    @Test func aReactionWithNoGroupToSealToGoesInTheClearCounted() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let reaction = ReactionRecord(messageId: "gm-x", reactor: me.nodeId, emoji: "\u{1F525}", updatedAt: now)
        fixture.engine.sendGroupReaction(reaction, in: nil)
        #expect(fixture.transport.written(.reaction).count == 1)
        #expect(fixture.engine.seals == RatchetSealCounts(reactionsSealedFallback: 1))
    }

    @Test(arguments: StoreKind.allCases)
    func aGroupSealWhoseWriteFailsSendsNothingAndTheHealRetriesIt(kind: StoreKind) throws {
        let directory = scratchDirectory("group-seal-fails")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingGroupWrites(blobs: directory, failures: ReportedFailures().record)
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        try fixture.pin(try AndroidPeer(alice))
        let group = fixture.holdGroup(with: [alice])
        fixture.deliver(try alice.groupMessage("hers", in: group, to: [me], id: "gm-alice", sentAt: now), from: alice)
        fixture.transport.clear()
        refusing.refusesWrites = true
        let message = try #require(fixture.engine.sendGroupMessage("not yet", to: group.id))
        _ = try #require(fixture.engine.react(to: "gm-alice", with: "\u{1F525}"))
        refusing.refusesWrites = false
        #expect(fixture.transport.written.isEmpty, "neither the message nor the reaction went, in any form")
        #expect(message.pendingKey && fixture.stores.groupRatchet.holdings(of: group.id) == .empty)
        #expect(fixture.engine.seals == RatchetSealCounts() && fixture.ratchetRecords(of: alice).session == nil)
        fixture.advance(MeshConfiguration().healMilliseconds)
        #expect(fixture.stores.messages.message(message.id)?.pendingKey == false && fixture.groupFrames(in: group.id).count == 1)
    }

    @Test func aReactionAskedForInsideAStoreUnitSendsNothing() throws {
        let fixture = try EngineFixture.ratcheting(me)
        try fixture.pin(try AndroidPeer(alice))
        let group = fixture.holdGroup(with: [alice])
        let record = try #require(fixture.stores.groups.group(group.id))
        let reaction = ReactionRecord(messageId: "gm-x", reactor: me.nodeId, emoji: "\u{1F525}", updatedAt: now)
        fixture.transport.clear()
        let unit = fixture.stores.transactor.atomically { () -> Void? in
            fixture.engine.sendGroupReaction(reaction, in: record)
            fixture.engine.flushPendingGroupKeys(for: alice.nodeId, force: true)
            return nil
        }
        guard case .abandoned = unit else {
            Issue.record("the outer unit: \(unit)")
            return
        }
        #expect(fixture.transport.written.isEmpty, "nothing goes before an outer commit it never sees")
        #expect(fixture.engine.seals == RatchetSealCounts())
    }

    /// A member we hold no session with and no prekey for: the floor opens, nothing can be sealed, and the floor is stamped
    /// all the same, as Kotlin's is, so it costs one try per floor. A request we would send ourselves answers nothing.
    @Test func aReSendNothingCanSealStampsTheFloorOnce() throws {
        let fixture = try EngineFixture.ratcheting(me)
        try fixture.pin(try AndroidPeer(alice))
        let group = fixture.holdGroup(with: [alice])
        _ = try #require(fixture.engine.sendGroupMessage("minted", to: group.id))
        // Her session goes, and a newer profile of hers carries no prekey, which clears its pin.
        fixture.stores.ratchet.deletePeer(alice.nodeId)
        fixture.advance(1)
        fixture.deliver(
            try alice.profile(publishedAt: fixture.clock.wallMilliseconds(), capabilities: AndroidPeer.capabilities), from: alice)
        #expect(fixture.stores.peers.peer(alice.nodeId)?.prekey == nil)
        #expect(fixture.engine.groupFloors.seeds[GroupSendFloors.Key(group.id, alice.nodeId)]?.root == nil, "stamped, nothing sealed")
        fixture.engine.flushPendingGroupKeys(for: alice.nodeId, force: false)
        let tries = fixture.log.all.filter { $0.contains("no group seed for \(group.id) to \(alice.nodeId): nothing to seal it with") }
        #expect(tries.count == 1 && fixture.chats(to: alice).count == 1, "floored: no second try, and only the mint's seed went")
        fixture.engine.redistributeGroupKey(in: group.id, to: me.nodeId)
        #expect(fixture.chats(to: me).isEmpty)
    }
}
