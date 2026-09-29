import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// v1 DMs both ways, receipts and message requests (`MeshManager.sendChat`, `flushPendingFor` and
/// `InboundPipeline.decryptAndDeliver`, `acknowledge` and `handleReceipt`).
@Suite struct MeshEngineDirectMessageTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    private func receivedRecords(_ events: [MeshEvent]) -> [(MessageRecord, Bool)] {
        events.compactMap { event in
            guard case .received(let record, let isRequest) = event else {
                return nil
            }
            return (record, isRequest)
        }
    }

    @Test func aDMToAPinnedPeerIsSealedSoOnlyTheRecipientCanOpenIt() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        fixture.transport.clear()
        let record = try #require(fixture.engine.sendDirectMessage("Hi Bob", to: bob.nodeId))
        #expect(!record.pendingKey)
        #expect(record.conversationId == bob.nodeId.string)
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(sent.to == nil, "a DM floods; there is no routing table")
        #expect(sent.envelope.recipientId == bob.nodeId.string)
        let chat = try ChatContent(decoding: sent.envelope.payload)
        #expect(chat.body.isEmpty, "nothing in the clear")
        let enc = try #require(chat.enc)
        #expect(enc.version == 1)
        let header = MessageCrypto.header(id: record.id, senderId: alice.nodeId.string, sentAt: record.sentAt, thread: bob.nodeId.string)
        #expect(MessageCrypto.open(enc, header: header, as: bob.keys)?.body == "Hi Bob")
        #expect(MessageCrypto.open(enc, header: header, as: carol.keys) == nil)
        #expect(fixture.stores.custody.contains(record.id))
    }

    @Test func aDMWaitsForItsRecipientsKeyThenGoesOutUnderItsOriginalId() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.transport.clear()
        let record = try #require(fixture.engine.sendDirectMessage("Before your key", to: bob.nodeId))
        #expect(record.pendingKey)
        #expect(fixture.transport.written(.chat).isEmpty)
        fixture.clock.advance(3000)
        try fixture.pin(bob)
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(sent.envelope.id == record.id && sent.envelope.sentAt == record.sentAt)
        #expect(fixture.engine.drainEvents().contains(.sent(messageId: record.id)))
        #expect(fixture.stores.messages.message(record.id)?.pendingKey == false)
        let enc = try #require(try ChatContent(decoding: sent.envelope.payload).enc)
        let header = MessageCrypto.header(id: record.id, senderId: alice.nodeId.string, sentAt: record.sentAt, thread: bob.nodeId.string)
        #expect(MessageCrypto.open(enc, header: header, as: bob.keys)?.body == "Before your key")
    }

    @Test func aDMToOurselvesOrABlankOneIsNotSent() {
        let fixture = EngineFixture(alice)
        #expect(fixture.engine.sendDirectMessage("Me", to: alice.nodeId) == nil)
        #expect(fixture.engine.sendDirectMessage("  ", to: bob.nodeId) == nil)
    }

    @Test func aStrangersFirstDMIsARequestThatStillEarnsAReceipt() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        let dm = try bob.directMessage("Hello Alice", to: alice, id: "dm-1", sentAt: EngineFixture.start)
        fixture.deliver(dm, from: bob)

        let received = receivedRecords(fixture.engine.drainEvents())
        #expect(received.map(\.0.body) == ["Hello Alice"])
        #expect(received.map(\.1) == [true], "unaccepted, so a message request")
        #expect(received.first?.0.conversationId == bob.nodeId.string)

        let receipt = try #require(fixture.transport.written(.receipt).first)
        #expect(receipt.to == nil && receipt.wire.relay, "a DM receipt floods")
        #expect(receipt.envelope.recipientId == nil)
        #expect(receipt.envelope.sentAt == EngineFixture.start, "sentAt set, or no carrier would hold it")
        #expect(try ReceiptContent(decoding: receipt.envelope.payload).ackId == "dm-1")
        #expect(fixture.stores.custody.contains(receipt.envelope.id), "our receipt is carried as ours")
        #expect(!fixture.stores.custody.contains("dm-1"), "and purges our own carried copy, as it purges every carrier's")
    }

    @Test func anAcceptedConversationIsNoLongerARequest() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        fixture.engine.accept(bob.nodeId.string)
        _ = fixture.engine.drainEvents()
        fixture.deliver(try bob.directMessage("Again", to: alice, id: "dm-2", sentAt: EngineFixture.start), from: bob)
        #expect(receivedRecords(fixture.engine.drainEvents()).map(\.1) == [false])
    }

    @Test func writingToSomeoneAcceptsTheirReplies() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        fixture.engine.sendDirectMessage("I wrote first", to: bob.nodeId)
        _ = fixture.engine.drainEvents()
        fixture.deliver(try bob.directMessage("Reply", to: alice, id: "dm-3", sentAt: EngineFixture.start), from: bob)
        #expect(receivedRecords(fixture.engine.drainEvents()).map(\.1) == [false])
    }

    @Test func aReServedDMIsNotAnnouncedAgainButIsAcknowledgedAgain() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let dm = try bob.directMessage("Once", to: alice, id: "dm-4", sentAt: EngineFixture.start)
        fixture.deliver(dm, from: bob)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        fixture.clock.advance(SeenSetWindow.milliseconds)
        fixture.deliver(dm, from: bob)
        #expect(receivedRecords(fixture.engine.drainEvents()).isEmpty)
        #expect(fixture.transport.written(.receipt).count == 1)
        #expect(!fixture.stores.custody.contains("dm-4"), "tombstoned, so it is not carried again")
    }

    @Test func someoneElsesDMIsCarriedAndRelayedButNotRead() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        let dm = try bob.directMessage("For Carol", to: carol, id: "dm-5", sentAt: EngineFixture.start)
        fixture.deliver(dm, from: bob)
        #expect(receivedRecords(fixture.engine.drainEvents()).isEmpty)
        #expect(fixture.transport.written(.receipt).isEmpty)
        #expect(fixture.stores.custody.contains("dm-5"))
        fixture.advance(150)
        #expect(fixture.transport.written(.chat).map(\.to) == [carol.nodeId])
    }

    @Test func someoneElsesDMThatLandsAfterItsReceiptIsRelayedButNotCarried() throws {
        // A back-fill serves Carol's receipt ahead of the older DM, or Carol receipts at once and relays the DM after
        // the jitter. Carried here, it would outlive every neighbour's copy (knit-next ADR 2026-09.adpz).
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        try fixture.pin(carol)
        fixture.transport.clear()
        fixture.deliver(try carol.receipt(for: "dm-9", id: "early", sentAt: EngineFixture.start), from: carol)
        fixture.deliver(try bob.directMessage("For Carol", to: carol, id: "dm-9", sentAt: EngineFixture.start), from: bob)
        #expect(!fixture.stores.custody.contains("dm-9"), "refused as the purge it missed would have left it")
        #expect(fixture.stores.custody.contains("early"))
        #expect(fixture.engine.footprint.tombstones == 1)
        fixture.advance(150)
        #expect(fixture.transport.written(.chat).map(\.to) == [carol.nodeId], "and still relayed")
    }

    @Test func aCleartextDMIsNeitherShownNorCarried() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        _ = fixture.engine.drainEvents()
        let envelope = RelayEnvelope(
            type: .chat,
            id: "dm-6",
            senderId: bob.nodeId.string,
            sentAt: EngineFixture.start,
            recipientId: alice.nodeId.string,
            payload: ChatContent(body: "Not sealed").encoded
        )
        fixture.deliver(try bob.signed(envelope), from: bob)
        #expect(receivedRecords(fixture.engine.drainEvents()).isEmpty)
        #expect(fixture.engine.dropped[.cleartextDirect] == 1)
        #expect(!fixture.stores.custody.contains("dm-6"))
    }

    @Test func aRatchetDMIsCarriedAndRelayedButCannotBeOpened() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        try fixture.pin(bob)
        fixture.transport.clear()
        let ratchet = EncEnvelope(version: EncEnvelope.Version.compactRatchet, nonce: [], ct: Array(repeating: 7, count: 40), keys: [])
        let envelope = RelayEnvelope(
            type: .chat,
            id: "dm-7",
            senderId: bob.nodeId.string,
            sentAt: EngineFixture.start,
            recipientId: alice.nodeId.string,
            payload: ChatContent(enc: ratchet).encoded
        )
        fixture.deliver(try bob.signed(envelope), from: bob)
        #expect(fixture.engine.dropped[.cannotOpen] == 1)
        #expect(fixture.stores.custody.contains("dm-7"))
        #expect(fixture.transport.written(.receipt).isEmpty)
    }

    @Test func aControlMessageIsNeverShownOrAcknowledged() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        let control = MessageContent(body: "", ctl: MessageContent.Control.receipt, ack: "x")
        fixture.deliver(try bob.directMessage("", to: alice, id: "dm-8", sentAt: EngineFixture.start, content: control), from: bob)
        #expect(receivedRecords(fixture.engine.drainEvents()).isEmpty)
        #expect(fixture.transport.written(.receipt).isEmpty)
    }

    @Test func aReceiptFromTheRecipientMarksOurDMDeliveredAndPurgesIt() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        try fixture.pin(carol)
        let record = try #require(fixture.engine.sendDirectMessage("Tick me", to: bob.nodeId))
        _ = fixture.engine.drainEvents()

        fixture.deliver(try carol.receipt(for: record.id, id: "forged", sentAt: EngineFixture.start), from: carol)
        #expect(fixture.engine.drainEvents().isEmpty, "only the recipient's receipt counts")
        #expect(fixture.stores.custody.contains(record.id))

        fixture.deliver(try bob.receipt(for: record.id, id: "real", sentAt: EngineFixture.start), from: bob)
        #expect(fixture.engine.drainEvents() == [.delivered(messageId: record.id)])
        #expect(!fixture.stores.custody.contains(record.id), "the recipient's receipt is the vaccine")
    }

    @Test func aSealedDMToSomeoneElseAddressedLikeOursIsNotOpened() throws {
        // Addressed to a string that is not a node id: relayed as a DM, delivered to nobody.
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        _ = fixture.engine.drainEvents()
        let dm = try bob.directMessage("Nobody", to: alice, id: "dm-9", sentAt: EngineFixture.start)
        var envelope = dm.envelope
        envelope.recipientId = "not-a-node-id"
        fixture.deliver(try bob.signed(envelope), from: bob)
        #expect(receivedRecords(fixture.engine.drainEvents()).isEmpty)
    }
}
