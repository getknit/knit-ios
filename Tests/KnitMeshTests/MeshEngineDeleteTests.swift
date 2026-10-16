import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// Deleting a message or a chat (ADR 2026-10.u7cq): local, as `ChatViewModel.deleteMessage` and
/// `ChatListViewModel.deleteConversation` are in knit-next, and, unlike there, for good. A deleted message never comes
/// back, not from our own custody at the next start and not from a carrier that re-serves its frame.
@Suite struct MeshEngineDeleteTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private let start = EngineFixture.start
    private let jpeg = OutgoingPhoto(bytes: Array("a photo from the trail".utf8), mime: "image/jpeg")

    /// Alice, linked to Bob and Carol, with both pinned.
    private func linked() throws -> EngineFixture {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        try fixture.pin(carol)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        return fixture
    }

    // MARK: Staying gone

    @Test func aDeletedGroupMessageIsNotReplayedFromOurCustodyAtTheNextStart() throws {
        // Without the remembered id, `replayCustodiedGroupFrames` would deliver it again, notification and all, for as
        // long as our custody holds it: knit-next's own roadmap names this gap.
        let fixture = try linked()
        let info = roster([carol, bob, alice], createdBy: carol)
        fixture.deliver(try carol.groupMessage("Lunch?", in: info, to: [alice, bob], id: "gm-1", sentAt: start), from: carol)
        #expect(fixture.stores.custody.contains("gm-1"))
        #expect(fixture.engine.deleteMessage("gm-1"))
        #expect(fixture.stores.messages.message("gm-1") == nil)
        let restarted = EngineFixture(alice, stores: fixture.stores)
        #expect(announced(restarted.engine.drainEvents()).isEmpty)
        #expect(restarted.stores.messages.message("gm-1") == nil)
        #expect(restarted.stores.custody.contains("gm-1"), "still carried for the others")
    }

    @Test func aDeletedDmThatACarrierReServesStaysGoneAndIsStillAcknowledged() throws {
        // A v1 DM opens again however often it is served (ADR 2026-09.qsd9), where Android's ratchet refuses a spent
        // key. The receipt still goes, so the carrier that missed the first one purges its copy.
        let fixture = try linked()
        let frame = try bob.directMessage("Hello", to: alice, id: "dm-1", sentAt: start)
        fixture.deliver(frame, from: carol)
        #expect(fixture.stores.messages.message("dm-1") != nil)
        #expect(fixture.engine.deleteChat(bob.nodeId.string))
        let restarted = EngineFixture(alice, stores: fixture.stores)
        restarted.link(carol)
        restarted.transport.clear()
        _ = restarted.engine.drainEvents()
        restarted.deliver(frame, from: carol)
        #expect(announced(restarted.engine.drainEvents()).isEmpty)
        #expect(restarted.stores.messages.message("dm-1") == nil)
        let receipt = try #require(restarted.transport.written(.receipt).first)
        #expect(try ReceiptContent(decoding: receipt.envelope.payload).ackId == "dm-1")
    }

    @Test func aDeletedRoomPostThatIsFloodedAgainStaysGone() throws {
        let fixture = try linked()
        let post = try bob.roomPost("Anyone near the lake?", id: "post-1", sentAt: start)
        fixture.deliver(post, from: bob)
        #expect(fixture.engine.deleteMessage("post-1"))
        let restarted = EngineFixture(alice, stores: fixture.stores)
        restarted.link(carol)
        _ = restarted.engine.drainEvents()
        restarted.deliver(post, from: carol)
        #expect(announced(restarted.engine.drainEvents()).isEmpty)
        #expect(restarted.stores.messages.messages(in: Conversations.nearby).isEmpty)
    }

    @Test func aDeletedIdIsForgottenAtTheFirstStartAfterNoCarrierCanHoldItsFrame() throws {
        let fixture = try linked()
        fixture.deliver(try bob.roomPost("Hi", id: "post-1", sentAt: start), from: bob)
        #expect(fixture.engine.deleteMessage("post-1"))
        let early = EngineFixture(alice, stores: fixture.stores, started: false)
        early.clock.advance(DeletedMessages.expiry(sentAt: start, deletedAt: start) - start)
        early.engine.start()
        #expect(early.stores.messages.contains("post-1"), "kept through its last instant")
        let late = EngineFixture(alice, stores: fixture.stores, started: false)
        late.clock.advance(DeletedMessages.expiry(sentAt: start, deletedAt: start) - start + 1)
        late.engine.start()
        #expect(!late.stores.messages.contains("post-1"))
    }

    // MARK: What a delete leaves alone

    @Test func aDeleteSendsNothingAndLeavesCustodyAsItWas() throws {
        // ADR 2026-10.5wgg's trap: a per-node input in custody would keep our digest from ever matching a neighbour's.
        let fixture = try linked()
        fixture.deliver(try bob.roomPost("Hi", id: "post-1", sentAt: start), from: bob)
        fixture.deliver(try bob.directMessage("Hello", to: alice, id: "dm-1", sentAt: start), from: bob)
        fixture.engine.postToRoom("Hello all")
        fixture.advance(1000)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        let cue = fixture.engine.digestCue
        let carried = fixture.stores.custody.liveFrames(now: fixture.clock.wallMilliseconds()).map(\.envelope.id)
        #expect(fixture.engine.deleteMessage("post-1"))
        #expect(fixture.engine.deleteChat(bob.nodeId.string))
        #expect(fixture.engine.deleteChat(Conversations.nearby))
        #expect(fixture.transport.written.isEmpty && fixture.transport.digests.isEmpty)
        #expect(fixture.engine.digestCue == cue)
        #expect(fixture.stores.custody.liveFrames(now: fixture.clock.wallMilliseconds()).map(\.envelope.id) == carried)
        #expect(fixture.engine.drainEvents().isEmpty)
    }

    @Test func aStatusLineIsNeverDeletedOnItsOwnButGoesWithItsChat() throws {
        let fixture = EngineFixture(alice)
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        let created = StatusNotices.groupCreated(group.id, by: alice.nodeId, at: start)
        #expect(!fixture.engine.deleteMessage(created.id))
        #expect(!fixture.engine.deleteMessage("nothing-here"))
        #expect(fixture.engine.deleteChat(group.id))
        #expect(fixture.stores.messages.messages(in: group.id).isEmpty)
        #expect(!fixture.engine.deleteChat(group.id), "nothing left to delete")
        let kept = try #require(fixture.stores.groups.group(group.id))
        #expect(!kept.hasLeft && kept.members == group.members, "we are still in it")
    }

    @Test func aGroupWhoseChatWasDeletedComesBackWithItsNextMessage() throws {
        let fixture = try linked()
        let info = roster([carol, bob, alice], createdBy: carol)
        fixture.deliver(try carol.groupMessage("Lunch?", in: info, to: [alice, bob], id: "gm-1", sentAt: start), from: carol)
        fixture.engine.accept(info.id)
        #expect(fixture.engine.deleteChat(info.id))
        #expect(!fixture.stores.messages.conversationIds().contains(info.id))
        _ = fixture.engine.drainEvents()
        fixture.deliver(try bob.groupMessage("Sure", in: info, to: [alice, carol], id: "gm-2", sentAt: start + 1), from: bob)
        let arrived = announced(fixture.engine.drainEvents())
        #expect(arrived.map(\.record.id) == ["gm-2"] && arrived.first?.isRequest == false)
        #expect(fixture.stores.messages.messages(in: info.id).map(\.id) == ["gm-2"])
    }

    // MARK: Acceptance

    @Test func aChatAcceptedBecauseWeWroteInItStaysAcceptedOnceDeleted() throws {
        // On Android it would turn into a request: there the user's own messages are what accepted it.
        let fixture = try linked()
        fixture.engine.sendDirectMessage("Hi Bob", to: bob.nodeId)
        #expect(!fixture.stores.conversations.acceptedConversations().contains(bob.nodeId.string))
        #expect(fixture.engine.deleteChat(bob.nodeId.string))
        #expect(fixture.stores.conversations.acceptedConversations().contains(bob.nodeId.string))
        _ = fixture.engine.drainEvents()
        fixture.deliver(try bob.directMessage("Hi Alice", to: alice, id: "dm-2", sentAt: start + 1), from: bob)
        #expect(announced(fixture.engine.drainEvents()).map(\.isRequest) == [false])
    }

    @Test func deletingOurOnlyMessageKeepsItsChatAccepted() throws {
        let fixture = try linked()
        let sent = try #require(fixture.engine.sendDirectMessage("Hi Bob", to: bob.nodeId))
        #expect(fixture.engine.deleteMessage(sent.id))
        #expect(fixture.stores.conversations.acceptedConversations() == [bob.nodeId.string])
    }

    @Test func aGroupWeMadeStaysAcceptedOnceItsCreatedLineGoes() throws {
        let fixture = EngineFixture(alice)
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        #expect(fixture.engine.deleteChat(group.id))
        #expect(fixture.stores.conversations.acceptedConversations() == [group.id])
    }

    @Test func aDeletedRequestIsNotAcceptedAndTheNextMessageIsARequestAgain() throws {
        let fixture = try linked()
        fixture.deliver(try bob.directMessage("Hello?", to: alice, id: "dm-1", sentAt: start), from: bob)
        #expect(fixture.engine.deleteChat(bob.nodeId.string))
        #expect(fixture.stores.conversations.acceptedConversations().isEmpty)
        _ = fixture.engine.drainEvents()
        fixture.deliver(try bob.directMessage("Hello again", to: alice, id: "dm-2", sentAt: start + 1), from: bob)
        #expect(announced(fixture.engine.drainEvents()).map(\.isRequest) == [true])
    }

    @Test func aGroupKnownOnlyThroughSomeoneBlockedIsNotAcceptedByADelete() throws {
        // The screens leave blocked senders out of the group rule (ADR 2026-10.5wgg), so this group reads as a request.
        let fixture = try linked()
        fixture.engine.accept(carol.nodeId.string)
        let info = roster([carol, bob, alice], createdBy: carol)
        fixture.deliver(try carol.groupMessage("Lunch?", in: info, to: [alice, bob], id: "gm-1", sentAt: start), from: carol)
        fixture.engine.block(carol.nodeId)
        #expect(fixture.engine.deleteChat(info.id))
        #expect(fixture.stores.conversations.acceptedConversations() == [carol.nodeId.string])
    }

    @Test func clearingTheRoomAcceptsNothing() throws {
        let fixture = try linked()
        fixture.deliver(try bob.roomPost("Hi", id: "post-1", sentAt: start), from: bob)
        #expect(fixture.engine.deleteChat(Conversations.nearby))
        #expect(fixture.stores.conversations.acceptedConversations().isEmpty)
        #expect(fixture.stores.messages.messages(in: Conversations.nearby).isEmpty)
    }

    // MARK: What it cancels and frees

    @Test func aDmDeletedWhileItWaitsForAKeyNeverLeaves() throws {
        // `flushPending` sends what the store holds, so the row was the only thing that would have sent it.
        let fixture = EngineFixture(alice)
        fixture.link(dave)
        let waiting = try #require(fixture.engine.sendDirectMessage("Hi Dave", to: dave.nodeId))
        #expect(waiting.pendingKey)
        #expect(fixture.engine.deleteMessage(waiting.id))
        fixture.transport.clear()
        try fixture.pin(dave)
        #expect(fixture.transport.written(.chat).isEmpty)
    }

    @Test func aDeletedPhotoStaysWhileOurCustodyCarriesItsFrameAndGoesAfter() throws {
        // Android keeps a carried frame's photo (`BlobRepository.deleteIfUnreferenced`). Ours, sent and deleted at once,
        // still goes out from custody, and its members fetch the photo from us, perhaps its only holder.
        let fixture = try linked()
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId]))
        let sent = try #require(fixture.engine.sendGroupMessage("", to: group.id, photo: jpeg))
        let hash = try #require(sent.attachment?.hash)
        #expect(!sent.pendingKey, "sealed to Bob and sent")
        #expect(fixture.engine.deleteMessage(sent.id))
        #expect(fixture.stores.custody.contains(sent.id))
        #expect(fixture.stores.blobs.contains(hash), "kept while its frame is carried")
        fixture.transport.clear()
        fixture.deliver(bob.blobRequest(for: hash.string, id: "breq-1"), from: bob)
        #expect(fixture.transport.files.map(\.hash) == [hash], "and served to a member who asks")
        let restarted = EngineFixture(alice, stores: fixture.stores)
        #expect(restarted.stores.blobs.contains(hash), "the start's sweep keeps it too")
        restarted.advance(CustodyLimits().ttlMilliseconds + MeshConfiguration().sweepMilliseconds)
        #expect(!restarted.stores.custody.contains(sent.id))
        #expect(!restarted.stores.blobs.contains(hash), "gone at the first sweep after its frame")
    }

    @Test func aDeletedPhotoThatNeverLeftGoesAtOnce() throws {
        // A group message waiting for a key is in no custody, and its delete cancels it.
        let fixture = EngineFixture(alice)
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId]))
        let waiting = try #require(fixture.engine.sendGroupMessage("", to: group.id, photo: jpeg))
        let hash = try #require(waiting.attachment?.hash)
        #expect(waiting.pendingKey)
        #expect(fixture.engine.deleteMessage(waiting.id))
        #expect(!fixture.stores.blobs.contains(hash))
    }

    @Test func aDeletedPhotoNoFrameOfOursCarriesGoesAtOnce() throws {
        // A DM's receipt purges every carrier's copy, the sender's included.
        let fixture = try linked()
        let sent = try #require(fixture.engine.sendDirectMessage("", to: bob.nodeId, photo: jpeg))
        let hash = try #require(sent.attachment?.hash)
        fixture.deliver(try bob.receipt(for: sent.id, id: "receipt-1", sentAt: start), from: bob)
        #expect(!fixture.stores.custody.contains(sent.id))
        #expect(fixture.engine.deleteMessage(sent.id))
        #expect(!fixture.stores.blobs.contains(hash), "not left for the next start's sweep")
    }

    @Test func aPhotoAnotherMessageStillShowsIsKept() throws {
        // A room photo is named by its own hash, so posting it twice names one blob twice. A room post is carried for
        // six hours.
        let fixture = EngineFixture(alice)
        let first = try #require(fixture.engine.postToRoom("", photo: jpeg))
        let second = try #require(fixture.engine.postToRoom("again", photo: jpeg))
        let hash = try #require(first.attachment?.hash)
        #expect(second.attachment?.hash == hash)
        #expect(fixture.engine.deleteMessage(first.id))
        fixture.advance(CustodyLimits().roomChatTTLMilliseconds + MeshConfiguration().sweepMilliseconds)
        #expect(fixture.stores.blobs.contains(hash), "the second post still shows it")
        #expect(fixture.engine.deleteMessage(second.id))
        #expect(!fixture.stores.blobs.contains(hash))
    }

    @Test func aPhotoStillOnItsWayStopsBeingWanted() throws {
        let fixture = try linked()
        let missing = BlobHash(of: Array("a sunset".utf8))
        let post = ChatContent(body: "Sunset", attachmentHash: missing.string, attachmentMime: "image/jpeg")
        fixture.deliver(
            try bob.signed(RelayEnvelope(type: .chat, id: "post-1", senderId: bob.nodeId.string, sentAt: start, payload: post.encoded)),
            from: bob
        )
        #expect(fixture.transport.accepted.contains(missing))
        #expect(fixture.engine.deleteChat(Conversations.nearby))
        #expect(!fixture.transport.accepted.contains(missing))
        fixture.engine.rewantMissingBlobs(sparing: [])
        #expect(!fixture.engine.blobExchange.isWanted(missing), "nothing names it any more")
    }
}
