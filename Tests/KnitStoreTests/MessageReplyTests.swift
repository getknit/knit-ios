import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The quote a reply carries, kept by every message store (schema v13 for the SQL one), and the rule that writes one
/// (ADR 2026-10.mn29).
@Suite struct MessageReplyTests {
    private static let kinds = RepositoryKind.allCases

    private let alice = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)

    private func message(_ id: String, body: String = "", replyingTo reply: MessageReply? = nil) -> MessageRecord {
        MessageRecord(id: id, senderId: bob, recipientId: nil, conversationId: Conversations.nearby, body: body, sentAt: 1, replyTo: reply)
    }

    /// A hash of one digit, `seed`, repeated.
    private func hash(_ seed: Int) -> BlobHash {
        BlobHash(String(repeating: String(seed % 10), count: 64)) ?? .empty
    }

    // MARK: The stores

    @Test(arguments: kinds)
    func aReplyKeepsItsQuote(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let quote = MessageReply(messageId: "m0", authorId: alice.string, author: "Ann", snippet: "see you", hasAttachment: true)
        let reply = message("reply", body: "on my way", replyingTo: quote)
        let plain = message("plain", body: "hi")
        store.save(reply)
        store.save(plain)
        #expect(store.message("reply") == reply)
        #expect(store.message("plain")?.replyTo == nil)
        #expect(store.messages(in: Conversations.nearby).map(\.replyTo) == [quote, nil])
    }

    /// The fields are the replier's: blank ones, and ids that are no frame id or node id, are kept as they came.
    @Test(arguments: kinds)
    func aQuoteIsKeptByItsBytes(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        // "K" and the Kelvin sign are one string to Swift and two to Android (ADR 2026-09.jc2x).
        let quote = MessageReply(messageId: "\u{212A}\u{0}", authorId: "not a node id", author: "", snippet: "")
        store.save(message("reply", replyingTo: quote))
        let kept = try #require(store.message("reply")?.replyTo)
        #expect(Array(kept.messageId.utf8) == Array("\u{212A}\u{0}".utf8))
        #expect(kept.authorId == "not a node id" && kept.author.isEmpty && kept.snippet.isEmpty && !kept.hasAttachment)
    }

    /// The first copy of a frame sets its quote (`saveIfAbsent`): a re-served one with another changes nothing, and every
    /// other write keeps it.
    @Test(arguments: kinds)
    func everyWriteKeepsTheQuote(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let quote = MessageReply(messageId: "m0", authorId: alice.string, author: "Ann", snippet: "see you")
        var ours = message("ours", body: "yes", replyingTo: quote)
        ours.senderId = alice
        ours.pendingKey = true
        store.save(ours)
        store.clearPendingKey("ours")
        store.markDelivered("ours")
        store.setModeration("ours", to: .flagged)
        #expect(store.message("ours")?.replyTo == quote)
        let other = MessageReply(messageId: "m9", authorId: bob.string, author: "Bo", snippet: "no")
        #expect(!store.insertIfAbsent(message("ours", replyingTo: other)))
        #expect(store.message("ours")?.replyTo == quote, "a re-served frame changes nothing")
        ours.replyTo = nil
        store.save(ours)
        #expect(store.message("ours")?.replyTo == nil, "a save writes the whole row")
    }

    // MARK: Writing a quote

    /// `ReplyFormattingTest.kt`'s cases, and the cut, which here never splits a scalar.
    @Test func aQuoteFlattensTheWordsAndCutsThem() {
        let parent = message("m1", body: "  one\n\ntwo\tthree  ")
        let quote = MessageReply.quoting(parent, authorName: "Bo", hidesWords: false, attachmentLabel: nil)
        #expect(quote == MessageReply(messageId: "m1", authorId: bob.string, author: "Bo", snippet: "one two three"))
        let long = MessageReply.quoting(
            message("m2", body: String(repeating: "a", count: 119) + "😀b"), authorName: "Bo", hidesWords: false, attachmentLabel: nil)
        #expect(long.snippet == String(repeating: "a", count: 119), "120 UTF-16 units, short of the pair the cut would split")
        let exact = MessageReply.quoting(
            message("m3", body: String(repeating: "b", count: 130)), authorName: "Bo", hidesWords: false, attachmentLabel: nil)
        #expect(exact.snippet.utf16.count == MessageReply.snippetLimit)
    }

    /// Words a tap would have had to reveal never ride a quote (`buildReplySnippet`'s `flagged`).
    @Test func hiddenWordsLeaveTheSnippetEmpty() {
        let quote = MessageReply.quoting(message("m1", body: "words"), authorName: "Bo", hidesWords: true, attachmentLabel: "🎞️ GIF")
        #expect(quote.snippet.isEmpty)
    }

    /// With no words, the label names what the message carried; a still photo takes none, and the flag says it was there.
    @Test func anAttachmentWithoutWordsTakesItsLabel() {
        var gif = message("m1", body: " ")
        gif.attachment = MessageAttachment(hash: hash(1), mime: "image/webp")
        #expect(MessageReply.quoting(gif, authorName: "Bo", hidesWords: false, attachmentLabel: "🎞️ GIF").snippet == "🎞️ GIF")
        let photo = MessageReply.quoting(gif, authorName: "Bo", hidesWords: false, attachmentLabel: nil)
        #expect(photo.snippet.isEmpty && photo.hasAttachment)
        var captioned = gif
        captioned.body = "look"
        #expect(MessageReply.quoting(captioned, authorName: "Bo", hidesWords: false, attachmentLabel: "🎞️ GIF").snippet == "look")
    }

    /// A link's card reads as its text (`ChatScreen.kt:1383-1385`).
    @Test func aLinksCardIsNoAttachment() {
        var card = message("m1", body: "https://example.com")
        card.attachment = MessageAttachment(hash: hash(2), mime: MessageAttachment.linkCardType)
        #expect(!MessageReply.quoting(card, authorName: "Bo", hidesWords: false, attachmentLabel: nil).hasAttachment)
        #expect(!MessageReply.quoting(message("m2", body: "hi"), authorName: "Bo", hidesWords: false, attachmentLabel: nil).hasAttachment)
    }
}
