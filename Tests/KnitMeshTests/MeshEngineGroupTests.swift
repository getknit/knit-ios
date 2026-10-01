import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// What we do in v1 groups (ADR 2026-09.n393): `ContactsViewModel.createGroup`, `MeshManager.sendChat`,
/// `sendGroupUpdate` and `sendGroupLeave`, as knit-next's `MeshManagerTest` pins them, and where this port differs.
@Suite struct MeshEngineGroupTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private let start = EngineFixture.start

    private var bobsGroup: GroupInfo { roster([bob, carol, alice], createdBy: bob) }

    // MARK: Making a group

    @Test func aNewGroupIsStoredWithItsCreatedLineAndNothingIsSent() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        #expect(group.members == [bob, carol, alice].map(\.nodeId.string), "the picks in order, then us")
        #expect(group.id == GroupId.derive(group.members))
        #expect(group.createdBy == alice.nodeId.string && group.createdAt == start)
        #expect(fixture.stores.groups.group(group.id) == group)
        #expect(fixture.stores.messages.messages(in: group.id) == [StatusNotices.groupCreated(group.id, by: alice.nodeId, at: start)])
        #expect(fixture.engine.drainEvents() == [.groupChanged(group.id)])
        #expect(fixture.transport.written.isEmpty, "members learn of a group from its first message")
        #expect(fixture.engine.createGroup(with: [carol.nodeId, bob.nodeId, bob.nodeId])?.id == group.id, "the same people")
    }

    @Test func aGroupNeedsOneToSevenOthers() {
        let fixture = EngineFixture(alice)
        #expect(fixture.engine.createGroup(with: []) == nil)
        #expect(fixture.engine.createGroup(with: [alice.nodeId]) == nil, "only us")
        let seven = (2...8).map { TestPeer(seed: $0).nodeId }
        #expect(fixture.engine.createGroup(with: seven)?.members.count == 8)
        #expect(fixture.engine.createGroup(with: seven + [TestPeer(seed: 9).nodeId]) == nil, "nine with us")
    }

    @Test func reCreatingAGroupWeLeftStartsItAfresh() throws {
        let fixture = EngineFixture(alice)
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        fixture.engine.renameGroup(group.id, to: "Hikers")
        #expect(fixture.engine.leaveGroup(group.id))
        fixture.clock.advance(1000)
        let again = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        #expect(again.id == group.id && again.name.isEmpty && !again.hasLeft && again.createdAt == start + 1000)
        #expect(fixture.stores.messages.messages(in: group.id).map(\.kind) == [.groupCreated])
    }

    // MARK: Sending

    @Test func aGroupMessageIsSealedToEachKeyedMemberWithTheRosterBesideIt() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        try fixture.pin(carol)
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId, dave.nodeId]))
        fixture.transport.clear()
        let record = try #require(fixture.engine.sendGroupMessage("Hi all", to: group.id))
        #expect(!record.pendingKey && record.recipientId == nil && record.conversationId == group.id)
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(sent.to == nil && sent.envelope.recipientId == nil)
        #expect(sent.envelope.group == group.info)
        #expect(sent.envelope.group?.name == nil && sent.envelope.group?.departed == nil)
        let enc = try #require(try ChatContent(decoding: sent.envelope.payload).enc)
        #expect(enc.keys.map(\.to) == [bob, carol].map(\.nodeId.string).sorted(), "never us, and never a member without a key")
        #expect(try opened(sent, as: bob)?.body == "Hi all")
        #expect(try opened(sent, as: carol)?.body == "Hi all")
        #expect(try opened(sent, as: dave) == nil)
        let asked = try fixture.transport.written(.keyRequest).map { try KeyRequestContent(decoding: $0.envelope.payload).nodeIds }
        #expect(asked == [[dave.nodeId.string]], "the missing member's key is asked for")
        #expect(fixture.stores.custody.contains(record.id))
    }

    @Test func aGroupMessageNobodyCanOpenYetWaitsForAKey() throws {
        let fixture = EngineFixture(alice)
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        let record = try #require(fixture.engine.sendGroupMessage("Before your keys", to: group.id))
        #expect(record.pendingKey)
        #expect(fixture.transport.written(.chat).isEmpty)
        _ = fixture.engine.drainEvents()
        fixture.clock.advance(3000)
        try fixture.pin(bob)
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(sent.envelope.id == record.id && sent.envelope.sentAt == record.sentAt, "its original id and clock")
        #expect(try opened(sent, as: bob)?.body == "Before your keys")
        #expect(fixture.engine.drainEvents().contains(.sent(messageId: record.id)))
        #expect(fixture.stores.messages.message(record.id)?.pendingKey == false)
        try fixture.pin(carol)
        #expect(fixture.transport.written(.chat).count == 1, "sent once")
    }

    @Test func aGroupMessageGoesNowhereItCannot() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId]))
        #expect(fixture.engine.sendGroupMessage("  ", to: group.id) == nil, "blank")
        #expect(fixture.engine.sendGroupMessage("Hi", to: "g-unknown") == nil, "no such group")
        fixture.deliver(try bob.groupLeave(group.id, id: "leave-1", sentAt: start), from: bob)
        #expect(fixture.engine.sendGroupMessage("Hi", to: group.id) == nil, "nobody else is left")
        fixture.engine.leaveGroup(group.id)
        #expect(fixture.engine.sendGroupMessage("Hi", to: group.id) == nil, "a group we left")
        #expect(fixture.engine.renameGroup(group.id, to: "Late") == nil)
    }

    // MARK: Renaming and leaving

    @Test func aRenameFloodsAGroupUpdateAndWritesNoLineHere() throws {
        let fixture = EngineFixture(alice)
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        _ = fixture.engine.drainEvents()
        #expect(fixture.engine.renameGroup(group.id, to: " \t ") == nil)
        let renamed = try #require(fixture.engine.renameGroup(group.id, to: "  Hiking \t club "))
        #expect(renamed.name == "Hiking club" && renamed.nameUpdatedAt == start)
        let update = try #require(fixture.transport.written(.groupUpdate).first)
        #expect(update.envelope.group == renamed.info && update.envelope.payload.isEmpty && update.envelope.sentAt == start)
        #expect(update.wire.relay)
        #expect(fixture.stores.messages.messages(in: group.id).map(\.kind) == [.groupCreated], "only receivers write a line")
        #expect(fixture.engine.drainEvents() == [.groupChanged(group.id)])
    }

    @Test func leavingTellsTheGroupAndForgetsTheThread() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let info = bobsGroup
        fixture.deliver(try bob.groupMessage("Hi", in: info, to: [alice], id: "gm-1", sentAt: start), from: bob)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        #expect(fixture.engine.leaveGroup(info.id))
        let leave = try #require(fixture.transport.written(.groupLeave).first)
        #expect(leave.envelope.group == nil, "a leave carries no roster")
        #expect(try GroupLeaveContent(decoding: leave.envelope.payload).groupId == info.id)
        #expect(fixture.stores.messages.messages(in: info.id).isEmpty)
        #expect(fixture.stores.groups.group(info.id)?.hasLeft == true)
        #expect(fixture.engine.drainEvents() == [.groupChanged(info.id)])
        #expect(!fixture.engine.leaveGroup(info.id), "already left")
        fixture.deliver(try bob.groupMessage("Still here?", in: info, to: [alice], id: "gm-2", sentAt: start), from: bob)
        #expect(fixture.engine.drainEvents().isEmpty, "a group we left never comes back")
        #expect(fixture.stores.messages.messages(in: info.id).isEmpty)
    }

    @Test func aMemberWhoLeftIsWrappedToNoMore() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        try fixture.pin(carol)
        let info = bobsGroup
        fixture.deliver(try bob.groupMessage("Hi", in: info, to: [alice, carol], id: "gm-1", sentAt: start), from: bob)
        fixture.deliver(try carol.groupLeave(info.id, id: "leave-1", sentAt: start + 10), from: carol)
        fixture.transport.clear()
        _ = try #require(fixture.engine.sendGroupMessage("Just us", to: info.id))
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(sent.envelope.group?.departed == [carol.nodeId.string])
        #expect(try ChatContent(decoding: sent.envelope.payload).enc?.keys.map(\.to) == [bob.nodeId.string])
    }

    @Test func aTickFromAnyMemberMarksOurGroupMessageDelivered() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        let record = try #require(fixture.engine.sendGroupMessage("Hi", to: group.id))
        _ = fixture.engine.drainEvents()
        fixture.deliver(try bob.receipt(for: "created:\(group.id)", id: "r-0", relay: false), from: bob)
        #expect(fixture.engine.drainEvents().isEmpty, "a status line is no message to tick")
        fixture.deliver(try bob.receipt(for: record.id, id: "r-1", relay: false), from: bob)
        #expect(fixture.engine.drainEvents() == [.delivered(messageId: record.id)])
        #expect(fixture.stores.messages.message(record.id)?.delivered == true)
    }
}
