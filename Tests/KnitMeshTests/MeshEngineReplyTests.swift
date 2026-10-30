import KnitCrypto
import KnitMesh
import KnitStore
import KnitTestSupport
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

    /// A quote whose original is held nowhere here is kept as its sender wrote it, unchecked (knit-next ADR 2026-10.gpa3).
    @Test func aRoomReplyKeepsItsQuoteThoughNothingHereHoldsWhatItQuotes() throws {
        let fixture = try fixture()
        let post = try bob.roomPost("", id: frameIdOf("r1"), sentAt: start, content: ChatContent(body: "on my way", replyTo: ref))
        fixture.deliver(post, from: bob)
        let stored = try #require(fixture.stores.messages.message(frameIdOf("r1")))
        #expect(stored.replyTo == quote && stored.replyCheck == .unchecked)
        #expect(fixture.stores.messages.message(ref.messageId) == nil)
        #expect(announced(fixture.engine.drainEvents()).map(\.record.replyTo) == [quote])
    }

    @Test func aDMReplyKeepsTheQuoteFromInsideItsSeal() throws {
        let fixture = try fixture()
        let content = MessageContent(body: "on my way", replyTo: ref)
        fixture.deliver(try bob.directMessage("", to: alice, id: frameIdOf("dm-1"), sentAt: start, content: content), from: bob)
        #expect(fixture.stores.messages.message(frameIdOf("dm-1"))?.replyTo == quote)
    }

    /// `plaintextContent` takes the sealed content's quote, or none: a quote in the clear beside `enc` is no part of a
    /// sealed message (`InboundPipeline.kt:979-990`).
    @Test func aQuoteInTheClearBesideASealIsIgnored() throws {
        let fixture = try fixture()
        let header = MessageCrypto.header(id: frameIdOf("dm-2"), senderId: bob.nodeId.string, sentAt: start, thread: alice.nodeId.string)
        let sealed = try #require(
            try MessageCrypto.seal(MessageContent(body: "hi").encoded, header: header, to: [alice.nodeId: alice.keys.bundle]))
        let envelope = RelayEnvelope(
            type: .chat,
            id: frameIdOf("dm-2"),
            senderId: bob.nodeId.string,
            sentAt: start,
            recipientId: alice.nodeId.string,
            payload: ChatContent(enc: sealed, replyTo: ref).encoded
        )
        fixture.deliver(try bob.signed(envelope), from: bob)
        let stored = try #require(fixture.stores.messages.message(frameIdOf("dm-2")))
        #expect(stored.body == "hi" && stored.replyTo == nil)
    }

    @Test func aGroupReplyKeepsItsQuote() throws {
        let fixture = try fixture()
        let info = roster([bob, carol, alice], createdBy: bob)
        let content = MessageContent(body: "on my way", replyTo: ref)
        fixture.deliver(
            try bob.groupMessage("", in: info, to: [alice, carol], id: frameIdOf("gm-1"), sentAt: start, content: content), from: bob)
        #expect(fixture.stores.messages.message(frameIdOf("gm-1"))?.replyTo == quote)
    }

    /// A quote is bounded as its body is (`InboundPipeline.admitReply`): the name on one line at a name's length, kept as a
    /// record only, and the words at what a composer ever writes.
    @Test func anOversizedQuoteIsClipped() throws {
        let fixture = try fixture()
        let long = ReplyRef(
            messageId: ref.messageId,
            authorId: ref.authorId,
            author: "n\n" + String(repeating: "n", count: 300),
            snippet: String(repeating: "w", count: 300)
        )
        fixture.deliver(
            try bob.roomPost("", id: frameIdOf("r2"), sentAt: start, content: ChatContent(body: "hm", replyTo: long)), from: bob)
        let stored = try #require(fixture.stores.messages.message(frameIdOf("r2"))?.replyTo)
        #expect(stored.author == "n " + String(repeating: "n", count: 30))
        #expect(stored.snippet.utf16.count == MessageReply.snippetLimit)
        #expect(stored.messageId == ref.messageId && !stored.hasAttachment)
    }

    /// A quote whose ids are blank or past 64 UTF-16 units names no original, so it is dropped and the reply kept as a
    /// message quoting nothing (`MAX_QUOTED_ID`).
    @Test(arguments: [
        ("", "author"), (" ", "author"), ("id", ""), (String(repeating: "i", count: 65), "author"),
        ("id", String(repeating: "a", count: 65)),
    ])
    func aQuoteNamingNoOriginalIsDropped(messageId: String, authorId: String) throws {
        let fixture = try fixture()
        let malformed = ReplyRef(
            messageId: messageId, authorId: authorId == "author" ? carol.nodeId.string : authorId, author: "Ann", snippet: "hi")
        fixture.deliver(
            try bob.roomPost("", id: frameIdOf("r5"), sentAt: start, content: ChatContent(body: "hm", replyTo: malformed)), from: bob)
        let stored = try #require(fixture.stores.messages.message(frameIdOf("r5")))
        #expect(stored.body == "hm" && stored.replyTo == nil && stored.quoteModeration == .clear)
    }

    /// A quote's words wait for the content filter apart from the body's while its original is not held (knit-next ADR
    /// 2026-10.gpa3): a photo-only reply's body has nothing to screen, and a blank quote nothing either.
    @Test func aQuotesWordsWaitForTheFilterApartFromTheBody() throws {
        let fixture = try fixture()
        let hash = String(repeating: "a", count: 64)
        let worded = ChatContent(attachmentHash: hash, attachmentMime: "image/jpeg", replyTo: ref)
        fixture.deliver(try bob.roomPost("", id: frameIdOf("r3"), sentAt: start, content: worded), from: bob)
        let waiting = try #require(fixture.stores.messages.message(frameIdOf("r3")))
        #expect(waiting.moderation == .clear && waiting.quoteModeration == .waiting && waiting.replyCheck == .unchecked)
        var blank = ref
        blank.snippet = " "
        let wordless = ChatContent(attachmentHash: hash, attachmentMime: "image/jpeg", replyTo: blank)
        fixture.deliver(try bob.roomPost("", id: frameIdOf("r4"), sentAt: start + 1, content: wordless), from: bob)
        let clear = try #require(fixture.stores.messages.message(frameIdOf("r4")))
        #expect(clear.moderation == .clear && clear.quoteModeration == .clear)
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
