import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// What arrives in v1 groups (ADR 2026-09.n393): `InboundPipeline.handleChat`, `handleGroupUpdate`,
/// `handleGroupLeave` and `acknowledge`, as knit-next's `InboundPipelineTest` pins them, and where this port differs.
@Suite struct MeshEngineGroupInboundTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private let start = EngineFixture.start

    private var bobsGroup: GroupInfo { roster([bob, carol, alice], createdBy: bob) }

    // MARK: Messages

    @Test func aStrangersGroupIsARequestThatStillEarnsATick() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        let info = bobsGroup
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        fixture.deliver(try bob.groupMessage("Hello group", in: info, to: [alice, carol], id: "gm-1", sentAt: start), from: bob)
        let events = fixture.engine.drainEvents()
        #expect(events.first == .groupChanged(info.id))
        let delivered = announced(events)
        #expect(delivered.map(\.record.body) == ["Hello group"])
        #expect(delivered.map(\.isRequest) == [true], "nobody we know has written in it")
        #expect(delivered.first?.record.conversationId == info.id && delivered.first?.record.recipientId == nil)
        #expect(fixture.stores.groups.group(info.id)?.members == info.members)
        #expect(fixture.stores.messages.message("created:\(info.id)")?.senderId == bob.nodeId)
        let tick = try #require(fixture.transport.written(.receipt).first)
        #expect(tick.to == bob.nodeId && !tick.wire.relay, "a point-to-point tick, as for a room post")
        #expect(try ReceiptContent(decoding: tick.envelope.payload).ackId == "gm-1")
        fixture.engine.accept(info.id)
        fixture.deliver(try bob.groupMessage("Again", in: info, to: [alice], id: "gm-2", sentAt: start), from: bob)
        #expect(announced(fixture.engine.drainEvents()).map(\.isRequest) == [false])
    }

    @Test func aGroupIsAcceptedOnceSomeoneWeKnowWritesInIt() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        fixture.engine.setVerified(bob.nodeId, true)
        _ = fixture.engine.drainEvents()
        fixture.deliver(try bob.groupMessage("Hi", in: bobsGroup, to: [alice], id: "gm-1", sentAt: start), from: bob)
        #expect(announced(fixture.engine.drainEvents()).map(\.isRequest) == [false])
    }

    @Test func aReservedGroupMessageIsTickedAgainButNotAnnounced() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        let frame = try bob.groupMessage("Once", in: bobsGroup, to: [alice], id: "gm-1", sentAt: start)
        fixture.deliver(frame, from: bob)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        fixture.advance(11 * 60_000)
        fixture.deliver(frame, from: bob)
        #expect(announced(fixture.engine.drainEvents()).isEmpty)
        #expect(fixture.transport.written(.receipt).count == 1)
    }

    @Test func aGroupChatInTheClearIsDroppedThoughItsRosterCounts() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let info = bobsGroup
        let plain = RelayEnvelope(
            type: .chat,
            id: "plain-1",
            senderId: bob.nodeId.string,
            sentAt: start,
            group: info,
            payload: ChatContent(body: "Plain").encoded
        )
        _ = fixture.engine.drainEvents()
        fixture.deliver(try bob.signed(plain), from: bob)
        #expect(announced(fixture.engine.drainEvents()).isEmpty)
        #expect(fixture.engine.dropped[.cleartextGroup] == 1)
        #expect(fixture.stores.groups.group(info.id) != nil)
        #expect(!fixture.stores.custody.contains("plain-1"), "a group chat is carried only when sealed")
    }

    @Test func anUndecodableGroupChatIsDroppedBeforeItsRosterIsRead() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let info = bobsGroup
        let junk = RelayEnvelope(type: .chat, id: "junk-1", senderId: bob.nodeId.string, sentAt: start, group: info, payload: [0xFF])
        fixture.deliver(try bob.signed(junk), from: bob)
        #expect(fixture.engine.dropped[.undecodable] == 1)
        #expect(fixture.stores.groups.group(info.id) == nil)
    }

    @Test func aGroupFrameWhoseRosterDoesNotHashToItsIdIsCarriedAndRelayedButRefused() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        var forged = bobsGroup
        forged.id = "g-0123456789abcdef01234567"
        fixture.deliver(try bob.groupMessage("Forged", in: forged, to: [alice], id: "group-1", sentAt: start), from: bob)
        #expect(announced(fixture.engine.drainEvents()).isEmpty)
        #expect(fixture.engine.dropped[.rosterRefused] == 1)
        #expect(fixture.stores.custody.contains("group-1"))
        fixture.advance(150)
        #expect(fixture.transport.written(.chat).map(\.to) == [carol.nodeId])
    }

    @Test func aGroupWeAreNotInIsCarriedQuietly() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let theirs = roster([bob, carol], createdBy: bob)
        fixture.deliver(try bob.groupMessage("Not yours", in: theirs, to: [carol], id: "other-1", sentAt: start), from: bob)
        #expect(fixture.engine.dropped.isEmpty)
        #expect(fixture.stores.groups.groups().isEmpty)
        #expect(fixture.stores.custody.contains("other-1"))
    }

    @Test func aGroupControlMessageIsMachinery() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let control = MessageContent(body: "", ctl: MessageContent.Control.reaction)
        let frame = try bob.groupMessage("", in: bobsGroup, to: [alice], id: "ctl-1", sentAt: start, content: control)
        _ = fixture.engine.drainEvents()
        fixture.deliver(frame, from: bob)
        #expect(announced(fixture.engine.drainEvents()).isEmpty)
        #expect(!fixture.stores.messages.contains("ctl-1"))
    }

    // MARK: Names, leaves and returns

    @Test func aMembersRenameIsTakenNewestFirstWithALine() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let info = bobsGroup
        fixture.deliver(try bob.groupMessage("Hi", in: info, to: [alice], id: "gm-1", sentAt: start), from: bob)
        let named = roster([bob, carol, alice], name: "Hikers", createdBy: bob)
        fixture.deliver(try bob.groupUpdate(named, id: "up-1", sentAt: start + 1000), from: bob)
        let older = roster([bob, carol, alice], name: "Older", createdBy: bob)
        fixture.deliver(try bob.groupUpdate(older, id: "up-2", sentAt: start + 500), from: bob)
        #expect(fixture.stores.groups.group(info.id)?.name == "Hikers")
        let line = try #require(fixture.stores.messages.message("grename:\(info.id):\(start + 1000)"))
        #expect(line.senderId == bob.nodeId && line.body == "Hikers" && line.kind == .groupRenamed)
    }

    @Test func aMemberLeavesByTheirOwnLeave() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        try fixture.pin(carol)
        let info = bobsGroup
        fixture.deliver(try bob.groupMessage("Hi", in: info, to: [alice, carol], id: "gm-1", sentAt: start), from: bob)
        _ = fixture.engine.drainEvents()
        fixture.deliver(try carol.groupLeave(info.id, id: "leave-1", sentAt: start + 10), from: carol)
        #expect(fixture.engine.drainEvents() == [.groupChanged(info.id)])
        #expect(fixture.stores.groups.group(info.id)?.departed == [carol.nodeId.string])
        #expect(fixture.stores.messages.message("leave:\(info.id):\(carol.nodeId)")?.kind == .memberLeft)
        try fixture.pin(dave)
        fixture.deliver(try dave.groupLeave(info.id, id: "leave-2", sentAt: start + 20), from: dave)
        #expect(fixture.stores.groups.group(info.id)?.departed == [carol.nodeId.string], "a stranger's leave changes nothing")
    }

    @Test func aRosterFrameWithNoRosterChangesNothing() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let bare = RelayEnvelope(type: .groupUpdate, id: "up-1", senderId: bob.nodeId.string, sentAt: start, payload: [])
        fixture.deliver(try bob.signed(bare), from: bob)
        #expect(fixture.stores.groups.groups().isEmpty)
        #expect(fixture.engine.dropped.isEmpty)
    }

    @Test func aLeaveForAGroupWeDoNotHoldChangesNothing() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        fixture.deliver(try bob.groupLeave("g-unknown", id: "leave-1", sentAt: start), from: bob)
        let junk = RelayEnvelope(type: .groupLeave, id: "leave-2", senderId: bob.nodeId.string, sentAt: start, payload: [0xFF])
        fixture.deliver(try bob.signed(junk), from: bob)
        #expect(fixture.engine.dropped[.undecodable] == 1)
        #expect(fixture.stores.groups.groups().isEmpty)
    }

    @Test func aMemberWhoLeftComesBackByTheirOwnNewerFrame() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        try fixture.pin(carol)
        let info = bobsGroup
        fixture.deliver(try bob.groupMessage("Hi", in: info, to: [alice, carol], id: "gm-1", sentAt: start), from: bob)
        fixture.deliver(try carol.groupLeave(info.id, id: "leave-1", sentAt: start + 10), from: carol)
        fixture.deliver(try carol.groupMessage("Back", in: info, to: [alice, bob], id: "gm-2", sentAt: start + 20), from: carol)
        let group = try #require(fixture.stores.groups.group(info.id))
        #expect(group.members == [bob, alice, carol].map(\.nodeId.string))
        #expect(fixture.stores.messages.message("rejoin:\(info.id):\(carol.nodeId)")?.sentAt == start + 20)
        #expect(fixture.stores.messages.message("gm-2")?.body == "Back")
    }

    /// Android names the frame's `createdBy` unchecked, so a stranger naming us made the group ours (A6).
    @Test func aStrangerClaimingWeMadeTheirGroupStillGetsARequest() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let forged = roster([bob, carol, alice], createdBy: alice)
        _ = fixture.engine.drainEvents()
        fixture.deliver(try bob.groupMessage("Yours?", in: forged, to: [alice], id: "gm-1", sentAt: start), from: bob)
        #expect(fixture.stores.messages.message("created:\(forged.id)")?.senderId == bob.nodeId)
        #expect(announced(fixture.engine.drainEvents()).map(\.isRequest) == [true])
    }

    // MARK: Start-up

    @Test func startingDeliversGroupChatsCustodyHeldBeforeGroupsShowed() throws {
        let stores = MeshStores.inMemory()
        let info = bobsGroup
        let early = try bob.groupMessage("Carried", in: info, to: [alice], id: "gm-1", sentAt: start)
        let shown = try bob.groupMessage("Shown", in: info, to: [alice], id: "gm-2", sentAt: start)
        for frame in [early, shown] {
            let carried = CarriedFrame(envelope: frame.envelope, sig: frame.wire.sig, signed: frame.wire.signed)
            stores.custody.store(carried, origin: .relayed, now: start)
        }
        let row = MessageRecord(id: "gm-2", senderId: bob.nodeId, recipientId: nil, conversationId: info.id, body: "Shown", sentAt: start)
        stores.messages.save(row)
        // A carried frame only ever comes from a sender whose id parses; one that did not would be passed over.
        var stray = early.envelope
        stray.id = "stray-1"
        stray.senderId = "not a node id"
        stores.custody.store(CarriedFrame(envelope: stray, sig: early.wire.sig, signed: early.wire.signed), origin: .relayed, now: start)
        let fixture = EngineFixture(alice, stores: stores)
        #expect(announced(fixture.engine.drainEvents()).map(\.record.id) == ["gm-1"])
        #expect(fixture.stores.groups.group(info.id) != nil)
    }
}
