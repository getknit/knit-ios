import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// Blocking (ADR 2026-10.5wgg): a blocked sender's messages, roster changes and departures stop at the delivery path,
/// while their frames are carried, relayed and ticked as anyone's, as knit-next's `InboundPipelineTest`, `TimeLabTest`
/// and `BlockAndRequestLabTest` pin them (knit-next ADRs 010 and 2026-09.bts9).
@Suite struct MeshEngineBlockTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private let start = EngineFixture.start

    /// Alice, linked to Bob and Carol, with both pinned and Bob blocked.
    private func blockingBob() throws -> EngineFixture {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        try fixture.pin(carol)
        fixture.engine.block(bob.nodeId)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        return fixture
    }

    /// Carol's group with Bob and Alice in it, made on Alice's phone by Carol's first message.
    private func carolsGroup(in fixture: EngineFixture, with members: [TestPeer]) throws -> GroupInfo {
        let info = roster(members, createdBy: carol)
        let others = members.filter { $0 != carol }
        fixture.deliver(try carol.groupMessage("Welcome", in: info, to: others, id: "gm-welcome-\(info.id)", sentAt: start), from: carol)
        #expect(fixture.stores.groups.group(info.id) != nil)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        return info
    }

    // MARK: Messages

    @Test func aBlockedSendersRoomPostIsNotSurfacedButStillTickedCarriedAndRelayed() throws {
        // `aBlockedSendersBroadcastIsNotSurfacedButStillAcked` and `canCarryStillCarriesABlockedSender`.
        let fixture = try blockingBob()
        fixture.deliver(try bob.roomPost("Hi all", id: "post-1", sentAt: start), from: bob)
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.stores.messages.message("post-1") == nil)
        #expect(fixture.engine.dropped[.blocked] == 1)
        let tick = try #require(fixture.transport.written(.receipt).first)
        #expect(tick.to == bob.nodeId && !tick.wire.relay, "the point-to-point tick, so the block stays invisible")
        #expect(try ReceiptContent(decoding: tick.envelope.payload).ackId == "post-1")
        #expect(fixture.stores.custody.contains("post-1"), "carried like anyone's")
        fixture.advance(150)
        #expect(fixture.transport.written(.chat).map(\.to) == [carol.nodeId], "and relayed")
    }

    @Test func aBlockedSendersDmIsNeitherDeliveredNorAcknowledged() throws {
        // `aBlockedSendersDmIsNeitherDeliveredNorAcked`. Its receipt would flood and purge every carrier's copy.
        let fixture = try blockingBob()
        fixture.deliver(try bob.directMessage("Hello", to: alice, id: "dm-1", sentAt: start), from: bob)
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.stores.messages.message("dm-1") == nil)
        #expect(fixture.transport.written(.receipt).isEmpty)
        #expect(fixture.stores.custody.contains("dm-1"), "held in our own custody, so our digest folds it")
    }

    @Test func aDmReceivedWhileBlockedStaysUnseenAfterTheUnblockAndEarlierOnesComeBack() throws {
        // `TimeLabTest.aDmReceivedWhileBlockedStaysUnseenAfterTheUnblock`: nothing replays our own custody on an unblock,
        // and the copy we hold keeps every peer from serving it again.
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        fixture.deliver(try bob.directMessage("Before", to: alice, id: "dm-0", sentAt: start), from: bob)
        fixture.engine.block(bob.nodeId)
        fixture.deliver(try bob.directMessage("During", to: alice, id: "dm-1", sentAt: start + 1), from: bob)
        fixture.engine.unblock(bob.nodeId)
        _ = fixture.engine.drainEvents()
        fixture.advance(60_000)
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.stores.messages.message("dm-0")?.body == "Before", "a block deletes nothing")
        #expect(fixture.stores.messages.message("dm-1") == nil)
        #expect(fixture.stores.custody.contains("dm-1"))
        #expect(fixture.stores.blocks.blockedNodeIds().isEmpty)
    }

    @Test func aBlockedMembersGroupMessageIsNotSurfacedButStillTicked() throws {
        // `aBlockedMembersGroupMessageIsNotSurfacedButStillAcked`.
        let fixture = try blockingBob()
        let info = try carolsGroup(in: fixture, with: [carol, bob, alice])
        fixture.deliver(try bob.groupMessage("From Bob", in: info, to: [alice, carol], id: "gm-1", sentAt: start), from: bob)
        #expect(announced(fixture.engine.drainEvents()).isEmpty)
        #expect(fixture.stores.messages.message("gm-1") == nil)
        let ticks = fixture.transport.written(.receipt)
        #expect(ticks.map(\.to) == [bob.nodeId])
        #expect(try ticks.map { try ReceiptContent(decoding: $0.envelope.payload).ackId } == ["gm-1"])
        #expect(fixture.stores.groups.group(info.id)?.members == info.members, "Bob stays on the roster")
    }

    @Test func aBlockedMembersGroupMessageIsNotTickedInAGroupWeDoNotHoldOrHaveLeft() throws {
        // `ackBlockedRoomChat`: only a member ticks, as on the delivery path.
        let fixture = try blockingBob()
        let strangers = roster([bob, carol, alice], createdBy: bob)
        fixture.deliver(try bob.groupMessage("Hi", in: strangers, to: [alice, carol], id: "gm-1", sentAt: start), from: bob)
        #expect(fixture.stores.groups.group(strangers.id) == nil, "the frame makes no group")
        let left = try carolsGroup(in: fixture, with: [carol, bob, alice, dave])
        #expect(fixture.engine.leaveGroup(left.id))
        fixture.transport.clear()
        fixture.deliver(try bob.groupMessage("Still here", in: left, to: [carol, dave], id: "gm-2", sentAt: start), from: bob)
        #expect(fixture.transport.written(.receipt).isEmpty)
        #expect(fixture.engine.dropped[.blocked] == 2)
    }

    @Test func aGroupMessageSentDuringABlockIsDeliveredAtTheNextStartAfterTheUnblock() throws {
        // The limit ADR 2026-10.5wgg names, as Android's `replayCustodiedGroupFrames` has it: our own custody holds the
        // message, and the start-up replay delivers what it holds and the thread lacks.
        let fixture = try blockingBob()
        let info = try carolsGroup(in: fixture, with: [carol, bob, alice])
        fixture.deliver(try bob.groupMessage("During", in: info, to: [alice, carol], id: "gm-1", sentAt: start), from: bob)
        #expect(fixture.stores.messages.message("gm-1") == nil)
        let blockedStart = EngineFixture(alice, stores: fixture.stores)
        #expect(blockedStart.stores.messages.message("gm-1") == nil, "a start while blocked meets the gate")
        fixture.engine.unblock(bob.nodeId)
        let restarted = EngineFixture(alice, stores: fixture.stores)
        #expect(restarted.stores.messages.message("gm-1")?.body == "During")
    }

    @Test func aBlockedSendersPhotoIsNotFetchedButTheirProfilePhotoIs() throws {
        // A blocked message never reaches `wantBlob`; a profile is never gated (`InboundPipeline.kt:1180-1183`).
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        try fixture.pin(bob)
        fixture.engine.block(bob.nodeId)
        fixture.transport.clear()
        let posted = BlobHash(of: Array("a sunset".utf8))
        let post = ChatContent(body: "Sunset", attachmentHash: posted.string, attachmentMime: "image/jpeg")
        let frame = try bob.signed(
            RelayEnvelope(type: .chat, id: "post-1", senderId: bob.nodeId.string, sentAt: start, payload: post.encoded))
        fixture.deliver(frame, from: carol)
        #expect(fixture.transport.written(.blobRequest).isEmpty)
        let face = BlobHash(of: Array("a face".utf8))
        fixture.deliver(try bob.profile(version: start + 1, publishedAt: start + 1, avatarHash: face.string), from: carol)
        let asked = fixture.transport.written(.blobRequest)
        #expect(try asked.map { try BlobRequestContent(decoding: $0.envelope.payload).hash } == [face.string])
        #expect(fixture.stores.peers.peer(bob.nodeId)?.advertisedAvatarHash == face)
    }

    @Test func aParkedFrameFromABlockedSenderMeetsTheBlockWhenItsKeyPins() throws {
        // A block needs no pin, and the frames parked for the key replay through the same door.
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        fixture.engine.block(bob.nodeId)
        fixture.deliver(try bob.roomPost("Early", id: "post-1", sentAt: start), from: carol)
        #expect(fixture.engine.dropped[.noSenderKey] == 1)
        try fixture.pin(bob)
        #expect(announced(fixture.engine.drainEvents()).isEmpty)
        #expect(fixture.stores.messages.message("post-1") == nil)
        #expect(fixture.engine.dropped[.blocked] == 1)
    }

    // MARK: Groups

    @Test func aNewGroupWhoseCreatorIsBlockedIsRefusedThoughAMemberWeKnowRelaysIt() throws {
        // `aNewGroupWhoseCreatorIsBlockedIsRefused`.
        let fixture = try blockingBob()
        let info = roster([bob, carol, alice], createdBy: bob)
        fixture.deliver(try carol.groupMessage("Join us", in: info, to: [alice, bob], id: "gm-1", sentAt: start), from: carol)
        #expect(fixture.stores.groups.group(info.id) == nil)
        #expect(fixture.stores.messages.message("gm-1") == nil)
        #expect(fixture.transport.written(.receipt).isEmpty)
        #expect(fixture.engine.dropped[.blocked] == 1)
    }

    @Test func aGroupWeHoldStaysOpenToItsOtherMembersWhenItsCreatorIsBlocked() throws {
        // Only a group new to us is refused for its creator; one we already hold keeps working.
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        try fixture.pin(carol)
        let info = roster([bob, carol, alice], createdBy: bob)
        fixture.deliver(try bob.groupMessage("Made it", in: info, to: [alice, carol], id: "gm-0", sentAt: start), from: bob)
        fixture.engine.block(bob.nodeId)
        _ = fixture.engine.drainEvents()
        fixture.deliver(try carol.groupMessage("Hi", in: info, to: [alice, bob], id: "gm-1", sentAt: start), from: carol)
        #expect(announced(fixture.engine.drainEvents()).map(\.record.id) == ["gm-1"])
    }

    @Test func aBlockedMembersRenameIsIgnored() throws {
        // `groupFrameRefused`: a roster frame from a blocked sender changes nothing.
        let fixture = try blockingBob()
        let info = try carolsGroup(in: fixture, with: [carol, bob, alice])
        let renamed = roster([carol, bob, alice], name: "Bob's now", createdBy: carol)
        fixture.deliver(try bob.groupUpdate(renamed, id: "gu-1", sentAt: start + 1), from: bob)
        #expect(fixture.stores.groups.group(info.id)?.name.isEmpty == true)
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.engine.dropped[.blocked] == 1)
    }

    @Test func groupLeaveFromABlockedSenderIsIgnored() throws {
        // `groupLeaveFromABlockedSenderIsIgnored`: the roster keeps them, and no line says they left.
        let fixture = try blockingBob()
        let info = try carolsGroup(in: fixture, with: [carol, bob, alice])
        let lines = fixture.stores.messages.messages(in: info.id).count
        fixture.deliver(try bob.groupLeave(info.id, id: "gl-1", sentAt: start + 1), from: bob)
        #expect(fixture.stores.groups.group(info.id)?.members == info.members)
        #expect(fixture.stores.messages.messages(in: info.id).count == lines)
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.engine.dropped[.blocked] == 1)
    }

    // MARK: Keys and tags

    @Test func aRekeyedPeerWithABlockedDeviceTagIsBlockedBeforeItsParkedFramesLand() throws {
        // `applyDeviceTagBlockContinuity`: the same phone under new keys stays blocked, and what it sent before its
        // profile pinned meets the block.
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        let tag = "a1b2c3d4e5f60718"
        fixture.deliver(try bob.profile(publishedAt: start, deviceTag: tag), from: carol)
        fixture.engine.block(bob.nodeId)
        #expect(fixture.stores.blocks.isBlocked(deviceTag: tag), "the block takes the tag the profile carried")
        let rekeyed = TestPeer(seed: 5)
        fixture.deliver(try rekeyed.directMessage("New keys", to: alice, id: "dm-1", sentAt: start), from: carol)
        _ = fixture.engine.drainEvents()
        fixture.deliver(try rekeyed.profile(publishedAt: start, deviceTag: tag), from: carol)
        #expect(fixture.stores.blocks.blockedNodeIds() == [bob.nodeId, rekeyed.nodeId])
        #expect(fixture.stores.messages.message("dm-1") == nil)
        #expect(fixture.engine.dropped[.blocked] == 1)
        #expect(fixture.engine.drainEvents() == [.peerUpdated(rekeyed.nodeId)])
        fixture.deliver(try dave.profile(publishedAt: start, deviceTag: "ffffffffffffffff"), from: carol)
        #expect(!fixture.stores.blocks.blockedNodeIds().contains(dave.nodeId), "another tag blocks nobody")
    }

    @Test func aBlockedPeersProfileServedAgainIsStillAnUpdateOnlyWhenTheBlockFollowsIt() throws {
        // A pinned peer whose tag is blocked later is blocked by its next profile, even an unchanged one.
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        let tag = "0123456789abcdef"
        fixture.deliver(try dave.profile(publishedAt: start, deviceTag: tag), from: carol)
        fixture.deliver(try bob.profile(publishedAt: start, deviceTag: tag), from: carol)
        fixture.engine.block(bob.nodeId)
        _ = fixture.engine.drainEvents()
        let again = try dave.profile(publishedAt: start, deviceTag: tag)
        fixture.clock.advance(SeenSetWindow.milliseconds)
        fixture.deliver(again, from: carol)
        #expect(fixture.stores.blocks.blockedNodeIds() == [bob.nodeId, dave.nodeId])
        #expect(fixture.engine.drainEvents() == [.peerUpdated(dave.nodeId)])
        fixture.clock.advance(SeenSetWindow.milliseconds)
        fixture.deliver(again, from: carol)
        #expect(fixture.engine.drainEvents().isEmpty, "already blocked, so nothing changed")
    }

    @Test func aDmToABlockedPeerWaitsForTheUnblock() throws {
        // `MeshManager.flushPendingFor` returns early for a blocked recipient.
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        let record = try #require(fixture.engine.sendDirectMessage("Before your key", to: bob.nodeId))
        fixture.engine.block(bob.nodeId)
        try fixture.pin(bob)
        #expect(fixture.transport.written(.chat).isEmpty)
        #expect(fixture.stores.messages.message(record.id)?.pendingKey == true)
    }

    @Test func weNeverBlockOurselves() {
        let fixture = EngineFixture(alice)
        fixture.engine.block(alice.nodeId)
        #expect(fixture.stores.blocks.blockedNodeIds().isEmpty)
    }
}
