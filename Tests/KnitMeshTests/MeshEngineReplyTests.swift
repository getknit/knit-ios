import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// Quoted replies both ways (ADR 2026-10.mn29): a room post's quote in the clear, a DM's and a group message's sealed
/// inside, as `MeshManager.sendChat` writes them and `InboundPipeline.deliverChat` keeps them (`MeshManagerTest.kt:1588`).
@Suite struct MeshEngineReplyTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let start = EngineFixture.start

    /// Ann's "see you", as Bob quotes it: `vectors/wire-v1.json`'s `replyRef`, with real ids.
    private var ref: ReplyRef {
        ReplyRef(messageId: "AAAAAAAAAAAAAAAAAAAAAA", authorId: carol.nodeId.string, author: "Ann", snippet: "see you", hasAttachment: true)
    }

    private var quote: MessageReply {
        MessageReply(messageId: ref.messageId, authorId: ref.authorId, author: "Ann", snippet: "see you", hasAttachment: true)
    }

    private func fixture() throws -> EngineFixture {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        return fixture
    }

    /// The quote `written` carries in its sealed content, as `reader` opens it.
    private func sealedQuote(_ written: Written, as reader: TestPeer) throws -> ReplyRef? {
        let envelope = written.envelope
        let enc = try #require(try ChatContent(decoding: envelope.payload).enc)
        let thread = envelope.group?.id ?? envelope.recipientId ?? ""
        let header = MessageCrypto.header(id: envelope.id, senderId: envelope.senderId, sentAt: envelope.sentAt, thread: thread)
        return try #require(MessageCrypto.open(enc, header: header, as: reader.keys)).replyTo
    }

    // MARK: Taking one

    /// Nothing checks the quote: the message it names is held nowhere here (`InboundPipeline.kt:2714`).
    @Test func aRoomReplyKeepsItsQuoteThoughNothingHereHoldsWhatItQuotes() throws {
        let fixture = try fixture()
        let post = try bob.roomPost("", id: "r1", sentAt: start, content: ChatContent(body: "on my way", replyTo: ref))
        fixture.deliver(post, from: bob)
        let stored = try #require(fixture.stores.messages.message("r1"))
        #expect(stored.replyTo == quote)
        #expect(fixture.stores.messages.message(ref.messageId) == nil)
        #expect(announced(fixture.engine.drainEvents()).map(\.record.replyTo) == [quote])
    }

    @Test func aDMReplyKeepsTheQuoteFromInsideItsSeal() throws {
        let fixture = try fixture()
        let content = MessageContent(body: "on my way", replyTo: ref)
        fixture.deliver(try bob.directMessage("", to: alice, id: "dm-1", sentAt: start, content: content), from: bob)
        #expect(fixture.stores.messages.message("dm-1")?.replyTo == quote)
    }

    /// `plaintextContent` takes the sealed content's quote, or none: a quote in the clear beside `enc` is no part of a
    /// sealed message (`InboundPipeline.kt:979-990`).
    @Test func aQuoteInTheClearBesideASealIsIgnored() throws {
        let fixture = try fixture()
        let header = MessageCrypto.header(id: "dm-2", senderId: bob.nodeId.string, sentAt: start, thread: alice.nodeId.string)
        let sealed = try #require(
            try MessageCrypto.seal(MessageContent(body: "hi").encoded, header: header, to: [alice.nodeId: alice.keys.bundle]))
        let envelope = RelayEnvelope(
            type: .chat,
            id: "dm-2",
            senderId: bob.nodeId.string,
            sentAt: start,
            recipientId: alice.nodeId.string,
            payload: ChatContent(enc: sealed, replyTo: ref).encoded
        )
        fixture.deliver(try bob.signed(envelope), from: bob)
        let stored = try #require(fixture.stores.messages.message("dm-2"))
        #expect(stored.body == "hi" && stored.replyTo == nil)
    }

    @Test func aGroupReplyKeepsItsQuote() throws {
        let fixture = try fixture()
        let info = roster([bob, carol, alice], createdBy: bob)
        let content = MessageContent(body: "on my way", replyTo: ref)
        fixture.deliver(try bob.groupMessage("", in: info, to: [alice, carol], id: "gm-1", sentAt: start, content: content), from: bob)
        #expect(fixture.stores.messages.message("gm-1")?.replyTo == quote)
    }

    /// A peer's frame bounds the name and the words no more than an attachment's text.
    @Test func anOversizedQuoteIsClipped() throws {
        let fixture = try fixture()
        let long = ReplyRef(
            messageId: ref.messageId,
            authorId: ref.authorId,
            author: String(repeating: "n", count: 300),
            snippet: String(repeating: "w", count: 300)
        )
        fixture.deliver(try bob.roomPost("", id: "r2", sentAt: start, content: ChatContent(body: "hm", replyTo: long)), from: bob)
        let stored = try #require(fixture.stores.messages.message("r2")?.replyTo)
        #expect(stored.author.utf16.count == 256 && stored.snippet.utf16.count == 256)
        #expect(stored.messageId == ref.messageId && !stored.hasAttachment)
    }

    /// A quote is someone's words too: a reply waits for the content filter when its body or its snippet has any
    /// (ADR 2026-10.mn29), and only a reply with neither shows at once.
    @Test func aPhotoOnlyReplyWaitsForTheFilterWhenItsQuoteHasWords() throws {
        let fixture = try fixture()
        let hash = String(repeating: "a", count: 64)
        let worded = ChatContent(attachmentHash: hash, attachmentMime: "image/jpeg", replyTo: ref)
        fixture.deliver(try bob.roomPost("", id: "r3", sentAt: start, content: worded), from: bob)
        #expect(fixture.stores.messages.message("r3")?.moderation == .waiting)
        var blank = ref
        blank.snippet = " "
        let wordless = ChatContent(attachmentHash: hash, attachmentMime: "image/jpeg", replyTo: blank)
        fixture.deliver(try bob.roomPost("", id: "r4", sentAt: start + 1, content: wordless), from: bob)
        #expect(fixture.stores.messages.message("r4")?.moderation == .clear)
    }

    // MARK: Sending one

    @Test func ourRoomReplyCarriesItsQuoteInTheClear() throws {
        let fixture = try fixture()
        let record = try #require(fixture.engine.postToRoom("on my way", replyTo: quote))
        #expect(record.replyTo == quote)
        #expect(fixture.stores.messages.message(record.id)?.replyTo == quote)
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(try ChatContent(decoding: sent.envelope.payload).replyTo == ref)
    }

    /// The quote rides inside the ciphertext, and the shell in the clear carries none (`Wire.kt:212-215`).
    @Test func ourDMReplyCarriesItsQuoteSealedAndNothingBesideIt() throws {
        let fixture = try fixture()
        let record = try #require(fixture.engine.sendDirectMessage("on my way", to: bob.nodeId, replyTo: quote))
        #expect(record.replyTo == quote)
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(try ChatContent(decoding: sent.envelope.payload).replyTo == nil)
        #expect(try sealedQuote(sent, as: bob) == ref)
    }

    @Test func ourGroupReplyCarriesItsQuoteSealedAndNothingBesideIt() throws {
        let fixture = try fixture()
        try fixture.pin(carol)
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        fixture.transport.clear()
        let record = try #require(fixture.engine.sendGroupMessage("on my way", to: group.id, replyTo: quote))
        #expect(record.replyTo == quote)
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(try ChatContent(decoding: sent.envelope.payload).replyTo == nil)
        #expect(try sealedQuote(sent, as: bob) == ref)
        #expect(try sealedQuote(sent, as: carol) == ref)
    }

    /// The row keeps the quote, so a reply that waited for its recipient's key goes out with it.
    @Test func aReplyWaitingForAKeyKeepsItsQuote() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        let record = try #require(fixture.engine.sendDirectMessage("before your key", to: bob.nodeId, replyTo: quote))
        #expect(record.pendingKey)
        fixture.transport.clear()
        try fixture.pin(bob)
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(sent.envelope.id == record.id)
        #expect(try sealedQuote(sent, as: bob) == ref)
    }
}
