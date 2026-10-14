import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// Typing cues, sent and taken as `MeshManager.sendTyping` and `InboundPipeline.handleTyping` do in knit-next: a signed,
/// cleartext frame that goes one hop and is never carried, held for 12 s, pushed out by each cue and ended by a message.
@Suite struct MeshEngineTypingTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private let start = EngineFixture.start

    /// Alice, linked to Bob and Carol, with Bob, Carol and Dave pinned and their profiles' relays fired.
    private func linked() throws -> EngineFixture {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        try fixture.pin(carol)
        try fixture.pin(dave)
        fixture.advance(1000)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        return fixture
    }

    /// Who is typing where, by each picture `events` announced.
    private func pictures(_ events: [MeshEvent]) -> [[String: [NodeId]]] {
        events.compactMap { event in
            guard case .typing(let picture) = event else {
                return nil
            }
            return picture
        }
    }

    // MARK: Someone else's

    @Test func aRoomCueAsAndroidSendsItShowsInTheRoomAndIsNeverCarriedOrRelayed() throws {
        let fixture = try linked()
        let cue = try bob.typing(id: "t-1")
        #expect(cue.envelope.payload == [0xA0], "Android's `{}`, pinned by its IosPayloadShapesTest")
        let digest = fixture.engine.digestCue
        fixture.deliver(cue, from: bob)
        #expect(pictures(fixture.engine.drainEvents()) == [[Conversations.nearby: [bob.nodeId]]])
        #expect(fixture.engine.typingNow == [Conversations.nearby: [bob.nodeId]])
        #expect(!fixture.stores.custody.contains("t-1"))
        #expect(fixture.engine.digestCue == digest, "one digest, whatever this node shows")
        #expect(fixture.engine.dropped.isEmpty)
        fixture.advance(1000)
        #expect(fixture.transport.written(.typing).isEmpty, "never relayed")
        #expect(fixture.transport.written(.receipt).isEmpty, "never acknowledged")
    }

    @Test func aDirectCueShowsInItsSendersThreadAndOneForSomeoneElseIsIgnored() throws {
        let fixture = try linked()
        fixture.deliver(try bob.typing(id: "t-1", to: alice), from: bob)
        fixture.deliver(try carol.typing(id: "t-2", to: dave), from: carol)
        #expect(pictures(fixture.engine.drainEvents()) == [[bob.nodeId.string: [bob.nodeId]]])
    }

    @Test func aGroupCueShowsInAHeldGroupFromItsRosterAndNowhereElse() throws {
        let fixture = try linked()
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        _ = fixture.engine.drainEvents()
        fixture.deliver(try bob.typing(id: "t-1", groupId: group.id), from: bob)
        fixture.deliver(try dave.typing(id: "t-2", groupId: group.id), from: bob)
        fixture.deliver(try carol.typing(id: "t-3", groupId: "g-unknown"), from: carol)
        #expect(pictures(fixture.engine.drainEvents()) == [[group.id: [bob.nodeId]]], "Dave is on no roster, and g-unknown held nowhere")
        fixture.deliver(try carol.typing(id: "t-4", groupId: group.id), from: carol)
        #expect(fixture.engine.typingNow == [group.id: [bob.nodeId, carol.nodeId].sorted()])
    }

    @Test func aCueLapsesAfterTwelveSecondsAndEachCuePushesTheEndOut() throws {
        let fixture = try linked()
        fixture.deliver(try bob.typing(id: "t-1"), from: bob)
        _ = fixture.engine.drainEvents()
        #expect(fixture.engine.nextDeadline == fixture.clock.monotonicMilliseconds() + 12_000)
        fixture.advance(11_000)
        fixture.deliver(try bob.typing(id: "t-2"), from: bob)
        #expect(fixture.engine.drainEvents().isEmpty, "a refresh changes nobody's picture")
        fixture.advance(11_999)
        #expect(fixture.engine.typingNow == [Conversations.nearby: [bob.nodeId]])
        fixture.advance(1)
        #expect(pictures(fixture.engine.drainEvents()) == [[:]])
        #expect(fixture.engine.typingNow.isEmpty)
    }

    @Test func theirMessageEndsTheirCueAtOnceBeforeItIsAnnounced() throws {
        let fixture = try linked()
        fixture.deliver(try bob.typing(id: "t-1"), from: bob)
        fixture.deliver(try carol.typing(id: "t-2"), from: carol)
        _ = fixture.engine.drainEvents()
        fixture.deliver(try bob.roomPost("Here", id: "post-1", sentAt: start), from: bob)
        let events = fixture.engine.drainEvents()
        #expect(pictures(events) == [[Conversations.nearby: [carol.nodeId]]])
        guard case .typing = events.first else {
            Issue.record("the cue ends before the message shows")
            return
        }
    }

    @Test func aDirectMessageEndsOnlyItsOwnThreadsCue() throws {
        let fixture = try linked()
        fixture.deliver(try bob.typing(id: "t-1"), from: bob)
        fixture.deliver(try bob.typing(id: "t-2", to: alice), from: bob)
        _ = fixture.engine.drainEvents()
        fixture.deliver(try bob.directMessage("Psst", to: alice, id: "dm-1", sentAt: start), from: bob)
        #expect(fixture.engine.typingNow == [Conversations.nearby: [bob.nodeId]])
    }

    @Test func ourOwnCueComingBackIsIgnored() throws {
        let fixture = try linked()
        fixture.deliver(try alice.typing(id: "t-1"), from: bob)
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.engine.dropped.isEmpty)
    }

    @Test func aBlockedSendersCueIsDroppedAndEarnsNoTick() throws {
        let fixture = try linked()
        fixture.engine.block(bob.nodeId)
        fixture.deliver(try bob.typing(id: "t-1"), from: bob)
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.engine.dropped == [.blocked: 1])
        #expect(fixture.transport.written(.receipt).isEmpty)
    }

    @Test func aCueThatDoesNotDecodeIsCountedRatherThanReadAsTheRooms() throws {
        // knit-next `03c4c3b1`: a group cue whose id broke would otherwise light the room.
        let fixture = try linked()
        let broken = RelayEnvelope(type: .typing, id: "t-1", senderId: bob.nodeId.string, payload: [0x61, 0x78])
        fixture.deliver(try bob.signed(broken, relay: false), from: bob)
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.engine.dropped == [.undecodable: 1])
    }

    @Test func aCueFromSomeoneWhoseKeyIsMissingAsksForNothing() throws {
        let fixture = try linked()
        let stranger = TestPeer(seed: 9)
        fixture.deliver(try stranger.typing(id: "t-1"), from: bob)
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.engine.dropped == [.noSenderKey: 1])
        #expect(fixture.transport.written(.keyRequest).isEmpty, "worthless a moment later")
    }

    @Test func stoppingForgetsWhoIsTyping() throws {
        let fixture = try linked()
        fixture.deliver(try bob.typing(id: "t-1"), from: bob)
        _ = fixture.engine.drainEvents()
        fixture.engine.forgetTyping()
        fixture.engine.forgetTyping()
        #expect(pictures(fixture.engine.drainEvents()) == [[:]], "announced once")
        #expect(fixture.engine.nextDeadline != nil)
    }

    @Test func theBoardHoldsAtMostSixtyFourCuesAndAlwaysTakesARefresh() {
        var board = TypingBoard()
        // Each mutation is read out first: `#expect` cannot call a mutating member.
        let noted = (0..<TypingBoard.capacity).map { board.note(bob.nodeId, in: "g-\($0)", until: 100) }
        #expect(!noted.contains(false))
        let pastTheCap = board.note(bob.nodeId, in: "g-full", until: 100)
        #expect(!pastTheCap, "a new pair past the cap is ignored")
        let refreshed = board.note(bob.nodeId, in: "g-0", until: 500)
        #expect(!refreshed, "a refresh only moves the end")
        #expect(board.picture.count == TypingBoard.capacity, "one thread a pair")
        #expect(board.picture["g-full"] == nil)
        let lapsed = board.lapse(now: 100)
        #expect(lapsed)
        #expect(board.picture == ["g-0": [bob.nodeId]])
        #expect(board.nextDeadline == 500)
    }

    // MARK: Ours

    @Test func aRoomCueGoesToEveryNeighbourUnsealedAndUnrelayed() throws {
        let fixture = try linked()
        #expect(fixture.engine.noteTyping(in: Conversations.nearby))
        let cue = try #require(fixture.transport.written(.typing).first)
        #expect(fixture.transport.written(.typing).count == 1)
        #expect(cue.to == nil, "every link")
        #expect(!cue.wire.relay)
        #expect(cue.envelope.senderId == alice.nodeId.string)
        #expect(cue.envelope.recipientId == nil)
        #expect(cue.envelope.group == nil)
        #expect(cue.envelope.sentAt == fixture.clock.wallMilliseconds())
        #expect(cue.envelope.payload == [0xA0])
        #expect(alice.keys.bundle.isValidSignature(cue.wire.sig, for: cue.wire.signed))
        #expect(fixture.stores.custody.liveIds(now: start).allSatisfy { $0 != cue.envelope.id }, "never carried")
    }

    @Test func aDirectCueGoesOnlyToItsPeer() throws {
        let fixture = try linked()
        #expect(fixture.engine.noteTyping(in: bob.nodeId.string))
        let cue = try #require(fixture.transport.written(.typing).first)
        #expect(cue.to == bob.nodeId)
        #expect(cue.envelope.recipientId == bob.nodeId.string)
        #expect(cue.envelope.payload == [0xA0])
    }

    @Test func aGroupCueCarriesTheGroupsIdAndNoRoster() throws {
        let fixture = try linked()
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        fixture.transport.clear()
        #expect(fixture.engine.noteTyping(in: group.id))
        let cue = try #require(fixture.transport.written(.typing).first)
        #expect(cue.to == nil)
        #expect(cue.envelope.recipientId == nil)
        #expect(cue.envelope.group == nil, "the roster could crowd a small frame")
        #expect(try TypingContent(decoding: cue.envelope.payload) == TypingContent(groupId: group.id))
    }

    @Test func eachThreadTakesOneCueEveryEightSecondsEachWithAFreshId() throws {
        let fixture = try linked()
        #expect(fixture.engine.noteTyping(in: Conversations.nearby))
        #expect(!fixture.engine.noteTyping(in: Conversations.nearby))
        #expect(fixture.engine.noteTyping(in: bob.nodeId.string), "another thread has its own")
        fixture.advance(7999)
        #expect(!fixture.engine.noteTyping(in: Conversations.nearby))
        fixture.advance(1)
        #expect(fixture.engine.noteTyping(in: Conversations.nearby))
        let ids = fixture.transport.written(.typing).map(\.envelope.id)
        #expect(ids.count == 3)
        #expect(Set(ids).count == 3, "no seen set swallows the next one")
    }

    @Test func noCueGoesToAThreadWeCannotWriteIn() throws {
        let fixture = try linked()
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        #expect(fixture.engine.leaveGroup(group.id))
        fixture.engine.block(carol.nodeId)
        fixture.transport.clear()
        #expect(!fixture.engine.noteTyping(in: group.id), "a group we left")
        #expect(!fixture.engine.noteTyping(in: "g-unknown"), "a group we never held")
        #expect(!fixture.engine.noteTyping(in: carol.nodeId.string), "someone we blocked")
        #expect(!fixture.engine.noteTyping(in: alice.nodeId.string), "ourselves")
        #expect(!fixture.engine.noteTyping(in: "not a node id"))
        #expect(fixture.transport.written.isEmpty)
    }
}

extension TestPeer {
    /// A typing cue from this peer as Android sends one: in the room, or to `recipient`, or in `groupId`.
    func typing(id: String, to recipient: Self? = nil, groupId: String? = nil) throws -> TestFrame {
        let envelope = RelayEnvelope(
            type: .typing,
            id: id,
            senderId: nodeId.string,
            sentAt: EngineFixture.start,
            recipientId: recipient?.nodeId.string,
            payload: TypingContent(groupId: groupId).encoded
        )
        return try signed(envelope, relay: false)
    }
}
