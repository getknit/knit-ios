import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// Reactions (ADR 2026-10.ehe6): sent and taken as `MeshManager.sendReaction` and `InboundPipeline.handleReaction` do
/// in knit-next, toward a peer without the ratchet, which every iPhone is: a signed cleartext frame that names no
/// recipient, applied last writer wins, and never read by custody.
@Suite struct MeshEngineReactionTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let start = EngineFixture.start
    private let thumbs = "\u{1F44D}"
    private let heart = "\u{2764}\u{FE0F}"

    /// Alice, linked to Bob and Carol, with both pinned, holding Bob's room post `post-1`.
    private func holdingAPost(blocking blocked: TestPeer? = nil) throws -> EngineFixture {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        try fixture.pin(carol)
        fixture.deliver(try bob.roomPost("Anyone near the lake?", id: "post-1", sentAt: start), from: bob)
        if let blocked {
            fixture.engine.block(blocked.nodeId)
        }
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        return fixture
    }

    /// The reactions `events` announced.
    private func reacted(_ events: [MeshEvent]) -> [ReactionRecord] {
        events.compactMap { event in
            guard case .reacted(let reaction) = event else {
                return nil
            }
            return reaction
        }
    }

    /// Carol's reaction to `post-1`, unless told otherwise.
    private func reaction(_ emoji: String?, by reactor: TestPeer? = nil, on id: String = "post-1", at stamp: Int64) -> ReactionRecord {
        ReactionRecord(messageId: id, reactor: (reactor ?? carol).nodeId, emoji: emoji, updatedAt: stamp)
    }

    // MARK: Someone else's

    @Test func someonesReactionIsAppliedAnnouncedCarriedAndRelayed() throws {
        let fixture = try holdingAPost()
        fixture.deliver(try carol.reaction(thumbs, to: "post-1", id: "r-1", sentAt: start + 1), from: carol)
        let expected = reaction(thumbs, at: start + 1)
        #expect(reacted(fixture.engine.drainEvents()) == [expected])
        #expect(fixture.stores.messages.reactions(in: Conversations.nearby) == [expected])
        #expect(fixture.stores.custody.contains("r-1"), "carried for 24 hours, like any custodial frame")
        #expect(fixture.transport.written(.receipt).isEmpty, "a reaction is never acknowledged")
        fixture.advance(150)
        #expect(fixture.transport.written(.reaction).map(\.to) == [bob.nodeId], "and relayed")
    }

    @Test func framesThatArriveOutOfOrderConvergeOnTheNewest() throws {
        let fixture = try holdingAPost()
        fixture.deliver(try carol.reaction(heart, to: "post-1", id: "r-2", sentAt: start + 2), from: carol)
        fixture.deliver(try carol.reaction(thumbs, to: "post-1", id: "r-1", sentAt: start + 1), from: carol)
        #expect(fixture.stores.messages.reactions(in: Conversations.nearby) == [reaction(heart, at: start + 2)])
        fixture.deliver(try carol.reaction(nil, to: "post-1", id: "r-3", sentAt: start + 3), from: carol)
        fixture.deliver(try carol.reaction(thumbs, to: "post-1", id: "r-0", sentAt: start), from: carol)
        #expect(fixture.stores.messages.reactions(in: Conversations.nearby).isEmpty, "the retraction holds")
        #expect(fixture.stores.messages.reaction(on: "post-1", by: carol.nodeId) == reaction(nil, at: start + 3))
        #expect(reacted(fixture.engine.drainEvents()).map(\.emoji) == [heart, nil], "only what changed is announced")
    }

    @Test func aFarFutureStampIsClampedToFiveMinutesAhead() throws {
        // `InboundPipeline.clampFuture`: one far-future stamp must not outrank every honest update after it.
        let fixture = try holdingAPost()
        fixture.deliver(try carol.reaction(thumbs, to: "post-1", id: "r-1", sentAt: start + 3_600_000), from: carol)
        let clamped = fixture.clock.wallMilliseconds() + WireProtocol.maxFutureSkewMilliseconds
        #expect(fixture.stores.messages.reaction(on: "post-1", by: carol.nodeId)?.updatedAt == clamped)
    }

    @Test func aReactionThatOvertookItsMessageShowsOnceTheMessageLands() throws {
        let fixture = try holdingAPost()
        fixture.deliver(try carol.reaction(thumbs, to: "post-2", id: "r-1", sentAt: start + 1), from: carol)
        #expect(reacted(fixture.engine.drainEvents()).isEmpty, "nothing to show it on yet")
        #expect(fixture.stores.messages.reaction(on: "post-2", by: carol.nodeId) != nil, "kept all the same")
        fixture.deliver(try bob.roomPost("Later", id: "post-2", sentAt: start), from: bob)
        #expect(fixture.stores.messages.reactions(in: Conversations.nearby) == [reaction(thumbs, on: "post-2", at: start + 1)])
    }

    @Test func aReactionLeftWithNoMessageForADayIsForgotten() throws {
        let fixture = try holdingAPost()
        fixture.deliver(try carol.reaction(thumbs, to: "post-1", id: "r-1", sentAt: start), from: carol)
        fixture.deliver(try carol.reaction(thumbs, to: "post-9", id: "r-9", sentAt: start), from: carol)
        fixture.advance(Reactions.orphanGraceMilliseconds + 1)
        #expect(fixture.stores.messages.reaction(on: "post-9", by: carol.nodeId) == nil, "the sweep reaped it")
        #expect(fixture.stores.messages.reaction(on: "post-1", by: carol.nodeId) != nil, "a held message keeps its own")
    }

    // MARK: Refused

    @Test func aBlockedPersonsReactionIsCarriedButNeitherShownNorTicked() throws {
        // Not `dropBlocked`, which ticks a frame naming no recipient as a room post (`InboundPipeline.kt:633`).
        let fixture = try holdingAPost(blocking: bob)
        fixture.deliver(try bob.reaction(thumbs, to: "post-1", id: "r-1", sentAt: start + 1), from: bob)
        #expect(fixture.stores.messages.reaction(on: "post-1", by: bob.nodeId) == nil)
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.engine.dropped[.blocked] == 1)
        #expect(fixture.transport.written(.receipt).isEmpty, "no tick tells them")
        #expect(fixture.stores.custody.contains("r-1"))
    }

    @Test(arguments: ["lol", " ", "", String(repeating: "a", count: 33), "\u{2764}"])
    func aReactionThatIsNotOneEmojiIsRefusedAndStillCarried(text: String) throws {
        let fixture = try holdingAPost()
        fixture.deliver(try carol.reaction(text, to: "post-1", id: "r-1", sentAt: start + 1), from: carol)
        #expect(fixture.stores.messages.reaction(on: "post-1", by: carol.nodeId) == nil)
        #expect(fixture.engine.dropped[.reactionRefused] == 1)
        #expect(fixture.stores.custody.contains("r-1"), "custody keeps what Android keeps")
    }

    @Test func aReactionThatDoesNotDecodeIsDropped() throws {
        let fixture = try holdingAPost()
        let garbled = RelayEnvelope(type: .reaction, id: "r-1", senderId: carol.nodeId.string, sentAt: start, payload: Array("nope".utf8))
        fixture.deliver(try carol.signed(garbled), from: carol)
        #expect(fixture.engine.dropped[.undecodable] == 1)
        #expect(fixture.engine.drainEvents().isEmpty)
    }

    @Test func aReactionToADeletedMessageIsRefusedSilently() throws {
        let fixture = try holdingAPost()
        #expect(fixture.engine.deleteMessage("post-1"))
        fixture.deliver(try carol.reaction(thumbs, to: "post-1", id: "r-1", sentAt: start + 1), from: carol)
        #expect(fixture.stores.messages.reaction(on: "post-1", by: carol.nodeId) == nil)
        #expect(fixture.engine.drainEvents().isEmpty && fixture.engine.dropped.isEmpty)
    }

    @Test func aParkedReactionMeetsTheBlockWhenItsKeyPins() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        try fixture.pin(carol)
        fixture.deliver(try carol.roomPost("Hi", id: "post-1", sentAt: start), from: carol)
        fixture.engine.block(bob.nodeId)
        fixture.transport.clear()
        fixture.deliver(try bob.reaction(thumbs, to: "post-1", id: "r-1", sentAt: start + 1), from: carol)
        #expect(fixture.engine.dropped[.noSenderKey] == 1)
        try fixture.pin(bob)
        #expect(fixture.stores.messages.reaction(on: "post-1", by: bob.nodeId) == nil)
        #expect(fixture.engine.dropped[.blocked] == 1)
        #expect(fixture.transport.written(.receipt).isEmpty)
    }

    @Test func whatThisNodeShowsNeverChangesWhatItCarries() throws {
        // ADR 2026-10.5wgg's trap: a block, a refusal or a delete read by custody would split our digest from every
        // neighbour's for as long as it stood.
        let plain = try holdingAPost()
        let local = try holdingAPost(blocking: bob)
        #expect(local.engine.deleteMessage("post-1"))
        for fixture in [plain, local] {
            fixture.deliver(try bob.reaction(thumbs, to: "post-1", id: "r-1", sentAt: start + 1), from: bob)
            fixture.deliver(try carol.reaction("lol", to: "post-1", id: "r-2", sentAt: start + 1), from: carol)
            fixture.deliver(try carol.reaction(heart, to: "post-1", id: "r-3", sentAt: start + 2), from: carol)
        }
        #expect(plain.engine.digestCue == local.engine.digestCue)
        #expect(local.stores.custody.contains("r-1") && local.stores.custody.contains("r-2") && local.stores.custody.contains("r-3"))
    }

    // MARK: Ours

    @Test func ourReactionIsAppliedFloodedAndCarriedAsAndroidSendsIt() throws {
        let fixture = try holdingAPost()
        let ours = try #require(fixture.engine.react(to: "post-1", with: thumbs))
        let now = fixture.clock.wallMilliseconds()
        #expect(ours == reaction(thumbs, by: alice, at: now))
        #expect(fixture.stores.messages.reactions(in: Conversations.nearby) == [ours])
        let sent = try #require(fixture.transport.written(.reaction).first)
        #expect(sent.wire.relay && sent.to == nil, "flooded")
        #expect(sent.envelope.recipientId == nil && sent.envelope.group == nil, "naming nobody, as Android's fallback does")
        #expect(sent.envelope.sentAt == now, "one clock for the frame and the row, so its echo ties")
        #expect(sent.envelope.payload == ReactionContent(messageId: "post-1", emoji: thumbs).encoded)
        #expect(fixture.stores.custody.contains(sent.envelope.id))
        #expect(reacted(fixture.engine.drainEvents()).isEmpty, "our own is not announced")
    }

    @Test func pickingAnotherReplacesAndPickingTheSameTakesItBack() throws {
        let fixture = try holdingAPost()
        fixture.engine.react(to: "post-1", with: thumbs)
        fixture.clock.advance(10)
        #expect(fixture.engine.react(to: "post-1", with: heart)?.emoji == heart)
        fixture.clock.advance(10)
        let taken = try #require(fixture.engine.react(to: "post-1", with: heart))
        #expect(taken.emoji == nil)
        #expect(fixture.stores.messages.reactions(in: Conversations.nearby).isEmpty)
        let payloads = try fixture.transport.written(.reaction).map { try ReactionContent(decoding: $0.envelope.payload) }
        #expect(payloads.map(\.emoji) == [thumbs, heart, nil])
        let retraction = try #require(fixture.transport.written(.reaction).last)
        #expect(retraction.envelope.payload == ReactionContent(messageId: "post-1").encoded, "a retraction omits the emoji")
    }

    @Test func twoTapsInOneMillisecondStillOrder() throws {
        let fixture = try holdingAPost()
        fixture.engine.react(to: "post-1", with: thumbs)
        fixture.engine.react(to: "post-1", with: thumbs)
        let now = fixture.clock.wallMilliseconds()
        #expect(fixture.transport.written(.reaction).map(\.envelope.sentAt) == [now, now + 1])
        #expect(fixture.stores.messages.reaction(on: "post-1", by: alice.nodeId) == reaction(nil, by: alice, at: now + 1))
    }

    @Test func onlyAnEmojiOnAHeldOrdinaryMessageIsSent() throws {
        let fixture = try holdingAPost()
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        let created = StatusNotices.groupCreated(group.id, by: alice.nodeId, at: start)
        fixture.transport.clear()
        #expect(fixture.engine.react(to: "nothing-here", with: thumbs) == nil)
        #expect(fixture.engine.react(to: created.id, with: thumbs) == nil, "a status line takes none")
        #expect(fixture.engine.react(to: "post-1", with: "lol") == nil)
        #expect(fixture.transport.written(.reaction).isEmpty)
    }

    @Test func noFrameGoesOutThatCouldNotBeNewerThanOurOwnHeldReaction() throws {
        // Ours, stamped as far ahead as any receiver allows, comes back from a neighbour: a tap this millisecond cannot
        // outrank it anywhere, so nothing is sent rather than a frame every node would ignore.
        let fixture = try holdingAPost()
        fixture.deliver(try alice.reaction(thumbs, to: "post-1", id: "r-ahead", sentAt: start + 3_600_000), from: bob)
        fixture.transport.clear()
        #expect(fixture.engine.react(to: "post-1", with: heart) == nil)
        #expect(fixture.transport.written(.reaction).isEmpty)
        #expect(fixture.stores.messages.reaction(on: "post-1", by: alice.nodeId)?.emoji == thumbs)
    }

    @Test func aReactionFromNoNodeIdChangesNothing() throws {
        // `verify` refuses such a sender before the handler sees it; the handler still asks.
        let fixture = try holdingAPost()
        let payload = ReactionContent(messageId: "post-1", emoji: thumbs).encoded
        fixture.engine.handleReaction(RelayEnvelope(type: .reaction, id: "r-x", senderId: "not a node", sentAt: start, payload: payload))
        #expect(fixture.stores.messages.reactions(in: Conversations.nearby).isEmpty)
        #expect(fixture.engine.drainEvents().isEmpty && fixture.engine.dropped.isEmpty)
    }

    @Test func ourOwnFrameServedBackChangesNothingAndRestoresWhatAWipeLost() throws {
        let fixture = try holdingAPost()
        fixture.engine.react(to: "post-1", with: thumbs)
        fixture.clock.advance(10)
        fixture.engine.react(to: "post-1", with: thumbs)
        let frames = fixture.transport.written(.reaction).map { TestFrame(wire: $0.wire, envelope: $0.envelope) }
        // After a restart the seen set is empty, so a neighbour's back-fill reaches the handler: both frames tie or lose.
        // No reaction is made after the restart, whose generator would draw the same ids again.
        let restarted = EngineFixture(alice, stores: fixture.stores)
        restarted.link(bob)
        _ = restarted.engine.drainEvents()
        for frame in frames {
            restarted.deliver(frame, from: bob)
        }
        #expect(restarted.stores.messages.reaction(on: "post-1", by: alice.nodeId)?.emoji == nil, "the retraction holds")
        #expect(reacted(restarted.engine.drainEvents()).isEmpty)
        // A wiped phone holds nothing; the back-fill brings our reaction back, newest last as it was.
        let wiped = EngineFixture(alice)
        wiped.link(bob)
        try wiped.pin(bob)
        wiped.deliver(try bob.roomPost("Anyone near the lake?", id: "post-1", sentAt: start), from: bob)
        wiped.deliver(frames[0], from: bob)
        #expect(wiped.stores.messages.reactions(in: Conversations.nearby).map(\.emoji) == [thumbs])
        wiped.deliver(frames[1], from: bob)
        #expect(wiped.stores.messages.reactions(in: Conversations.nearby).isEmpty)
    }
}

extension TestPeer {
    /// A cleartext reaction to `messageId`, as Android floods it to a peer without the ratchet; `nil` takes it back.
    func reaction(_ emoji: String?, to messageId: String, id: String, sentAt: Int64) throws -> TestFrame {
        let payload = ReactionContent(messageId: messageId, emoji: emoji).encoded
        return try signed(RelayEnvelope(type: .reaction, id: id, senderId: nodeId.string, sentAt: sentAt, payload: payload))
    }
}
