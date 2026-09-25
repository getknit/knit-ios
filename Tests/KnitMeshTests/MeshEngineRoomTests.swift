import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// The Nearby room: posts, relays and ticks (`MeshManager.sendChat`, `InboundPipeline.deliverChat` and `AckSync`).
@Suite struct MeshEngineRoomTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    @Test func aPostIsStoredSignedFloodedAndCarried() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        fixture.transport.clear()
        let record = try #require(fixture.engine.postToRoom("Hello, room"))
        #expect(record.conversationId == Conversations.nearby)
        #expect(fixture.stores.messages.message(record.id) == record)
        let flooded = try #require(fixture.transport.written(.chat).first)
        #expect(flooded.to == nil)
        #expect(flooded.envelope.id == record.id)
        #expect(flooded.envelope.recipientId == nil && flooded.envelope.sentAt == record.sentAt)
        #expect(try ChatContent(decoding: flooded.envelope.payload).body == "Hello, room")
        #expect(alice.keys.bundle.isValidSignature(flooded.wire.sig, for: flooded.wire.signed))
        #expect(fixture.stores.custody.contains(record.id))
        #expect(FrameId.bytes(of: record.id) != nil, "a canonical 22-character id")
    }

    @Test func ourPostsEchoIsIgnored() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        let record = try #require(fixture.engine.postToRoom("Echo"))
        let echo = try #require(fixture.transport.written(.chat).first)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        fixture.engine.receive(InboundFrame(wire: echo.wire, envelope: echo.envelope, from: bob.nodeId))
        fixture.advance(1000)
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.transport.written(.chat).isEmpty, "a duplicate is never relayed")
        #expect(fixture.stores.messages.messages(in: Conversations.nearby) == [record])
    }

    @Test func aBlankPostIsNotSent() {
        let fixture = EngineFixture(alice)
        #expect(fixture.engine.postToRoom(" \n\t ") == nil)
        #expect(fixture.engine.postToRoom("") == nil)
        #expect(fixture.transport.written(.chat).isEmpty)
    }

    @Test func aLongPostIsCutToTheMessageLimit() throws {
        let fixture = EngineFixture(alice)
        let record = try #require(fixture.engine.postToRoom(String(repeating: "x", count: 2500)))
        #expect(record.body.utf16.count == TextLimits.message)
    }

    @Test func aPostFromALinkedAuthorIsDeliveredCarriedRelayedAndTicked() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        let post = try bob.roomPost("Hi all", id: "post-1", sentAt: EngineFixture.start)
        fixture.deliver(post, from: bob)

        let events = fixture.engine.drainEvents()
        guard case .received(let record, let isRequest)? = events.first else {
            Issue.record("expected a received message, got \(events)")
            return
        }
        #expect(record.body == "Hi all" && record.senderId == bob.nodeId && !isRequest)
        #expect(record.arrivedAt == EngineFixture.start)
        #expect(fixture.stores.custody.contains("post-1"))

        let tick = try #require(fixture.transport.written(.receipt).first)
        #expect(tick.to == bob.nodeId)
        #expect(!tick.wire.relay, "a room tick is point to point")
        #expect(tick.envelope.sentAt == 0, "and carries no sentAt, so nobody custodies it")
        #expect(try ReceiptContent(decoding: tick.envelope.payload).ackId == "post-1")

        #expect(fixture.transport.written(.chat).isEmpty, "the relay waits out its jitter")
        fixture.advance(150)
        let relayed = fixture.transport.written(.chat)
        #expect(relayed.map(\.to) == [carol.nodeId])
        #expect(relayed.first?.wire.hops == 1)
        #expect(relayed.first?.wire.signed == post.wire.signed)
    }

    @Test func aTickOwedToAnUnlinkedAuthorGoesOutWhenItLinks() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        try fixture.pin(bob)
        fixture.deliver(try bob.roomPost("Via carol", id: "post-2", sentAt: EngineFixture.start), from: carol)
        #expect(fixture.transport.written(.receipt).isEmpty)
        fixture.link(bob)
        let ticks = fixture.transport.written(.receipt)
        #expect(ticks.map(\.to) == [bob.nodeId])
        #expect(ticks.compactMap { try? ReceiptContent(decoding: $0.envelope.payload).ackId } == ["post-2"])
    }

    @Test func aTickIsOwedOnceAndSentOnce() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        try fixture.pin(bob)
        let post = try bob.roomPost("Twice", id: "post-3", sentAt: EngineFixture.start)
        fixture.deliver(post, from: carol)
        fixture.clock.advance(SeenSetWindow.milliseconds)
        fixture.deliver(post, from: carol)
        fixture.link(bob)
        fixture.engine.linkUp(Neighbor(nodeId: bob.nodeId))
        #expect(fixture.transport.written(.receipt).count == 1)
    }

    @Test func aPostFromAnUnknownSenderIsParkedUntilItsKeyArrives() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        fixture.transport.clear()
        let post = try bob.roomPost("Early", id: "post-4", sentAt: EngineFixture.start)
        fixture.deliver(post, from: carol)
        #expect(fixture.engine.dropped[.noSenderKey] == 1)
        #expect(!fixture.stores.custody.contains("post-4"), "custody needs the sender's key")
        let request = try #require(fixture.transport.written(.keyRequest).first)
        #expect(request.to == carol.nodeId && !request.wire.relay)
        #expect(try KeyRequestContent(decoding: request.envelope.payload).nodeIds == [bob.nodeId.string])
        _ = fixture.engine.drainEvents()

        try fixture.pin(bob)
        let delivered = fixture.engine.drainEvents().compactMap { event -> String? in
            guard case .received(let record, _) = event else {
                return nil
            }
            return record.id
        }
        #expect(delivered == ["post-4"])
        #expect(fixture.stores.custody.contains("post-4"), "the replay carries it too")
    }

    @Test func aTickFromAnyoneMarksOurPostDelivered() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        try fixture.pin(carol)
        let post = try #require(fixture.engine.postToRoom("Anyone?"))
        _ = fixture.engine.drainEvents()
        fixture.deliver(try carol.receipt(for: post.id, id: "tick-1", relay: false), from: carol)
        #expect(fixture.engine.drainEvents() == [.delivered(messageId: post.id)])
        #expect(fixture.stores.messages.message(post.id)?.delivered == true)
        fixture.deliver(try carol.receipt(for: post.id, id: "tick-2", relay: false), from: carol)
        #expect(fixture.engine.drainEvents().isEmpty, "✓✓ flips once")
    }

    @Test func aReceiptForSomeoneElsesPostChangesNothing() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        try fixture.pin(bob)
        try fixture.pin(carol)
        fixture.deliver(try bob.roomPost("Bob's", id: "post-5", sentAt: EngineFixture.start), from: carol)
        _ = fixture.engine.drainEvents()
        fixture.deliver(try carol.receipt(for: "post-5", id: "tick-3", sentAt: EngineFixture.start), from: carol)
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.stores.messages.message("post-5")?.delivered == false)
    }
}

/// The router's seen window, for a test that waits it out.
enum SeenSetWindow {
    static let milliseconds = SeenSet.defaultWindowMilliseconds
}
