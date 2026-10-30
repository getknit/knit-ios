import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// A received quote judged against the original it names, and every message store's settle (knit-next ADR 2026-10.gpa3,
/// `QuoteCheckTest.kt` and `QuoteVerifierTest.kt` at `7439fd9cc`), apart so the suite stays inside the lint's length.
extension MessageReplyTests {
    private static let ann = fixtureNodeId(3)
    private static let bob = fixtureNodeId(2)
    private static let me = fixtureNodeId(1)

    /// Bob's reply in `thread`, quoting `quoted` by `author`, with `snippet` as he claims it.
    private static func reply(
        _ id: String = "reply", quoting quoted: String = "orig", by author: NodeId = ann, in thread: String = Conversations.nearby,
        snippet: String = "forged words", from sender: NodeId = bob
    ) -> MessageRecord {
        let quote = MessageReply(messageId: quoted, authorId: author.string, author: "Anyone", snippet: snippet, hasAttachment: true)
        return MessageRecord(
            id: id,
            senderId: sender,
            recipientId: nil,
            conversationId: thread,
            body: "yes",
            sentAt: 2,
            arrivedAt: 2,
            replyTo: quote
        )
    }

    /// Ann's original in `thread`.
    private static func original(
        _ id: String = "orig", body: String = "  meet\nat six ", by author: NodeId = ann, in thread: String = Conversations.nearby
    ) -> MessageRecord {
        MessageRecord(id: id, senderId: author, recipientId: nil, conversationId: thread, body: body, sentAt: 1, arrivedAt: 1)
    }

    private static func settlement(_ reply: MessageRecord, _ original: MessageRecord) -> QuoteSettlement {
        MessageReply.settlement(of: reply, against: original) { _ in "🎤 Voice message" }
    }

    // MARK: The verdict

    /// The codes are Android's and stored on the row, so they never move (`QuoteCheckTest`'s pin).
    @Test func theChecksCodesAreAndroids() {
        #expect([QuoteCheck.unchecked, .verified, .mismatch].map(\.rawValue) == [0, 1, 2])
    }

    /// Only the original in the reply's thread, by the author the quote names, an ordinary message and not the reply
    /// itself, verifies; anything else that answers to the id is a mismatch (`quoteVerdict`).
    @Test func onlyTheNamedAuthorsMessageInTheThreadVerifies() {
        let reply = Self.reply()
        #expect(MessageReply.verdict(of: reply, against: Self.original()) == .verified)
        #expect(MessageReply.verdict(of: reply, against: Self.original(by: Self.bob)) == .mismatch, "another author")
        #expect(MessageReply.verdict(of: reply, against: Self.original(in: "g-other")) == .mismatch, "another thread")
        var notice = Self.original()
        notice.kind = .memberLeft
        #expect(MessageReply.verdict(of: reply, against: notice) == .mismatch, "a status line is nobody's words")
        #expect(MessageReply.verdict(of: Self.original(), against: Self.original()) == .mismatch, "a row that quotes nothing")
        #expect(Self.original().settled(with: Self.settlement(reply, Self.original())) == Self.original(), "nothing to settle")
        let itself = Self.reply(quoting: "reply", by: Self.bob)
        #expect(MessageReply.verdict(of: itself, against: itself) == .mismatch, "a reply cannot quote itself")
        // A node id compares by its bytes, as every id does (ADR 2026-09.jc2x).
        var kelvin = Self.reply()
        kelvin.replyTo?.authorId = "\u{212A}" + Self.ann.string.dropFirst()
        #expect(MessageReply.verdict(of: kelvin, against: Self.original()) == .mismatch)
    }

    /// A verified quote is rebuilt from the original by the composer's rule, with the reader's label and the original's
    /// attachment flag, whatever the sender claimed; a mismatch keeps nothing of the claim.
    @Test func aVerifiedQuoteIsRebuiltAndAMismatchKeepsNothing() {
        let verified = Self.settlement(Self.reply(), Self.original())
        #expect(verified == QuoteSettlement(check: .verified, snippet: "meet at six", hasAttachment: false, moderation: .clear))
        var voice = Self.original(body: "")
        voice.attachment = MessageAttachment(hash: BlobHash(String(repeating: "7", count: 64)) ?? .empty, mime: "audio/mp4")
        let labelled = Self.settlement(Self.reply(), voice)
        #expect(labelled.snippet == "🎤 Voice message" && labelled.hasAttachment)
        #expect(Self.settlement(Self.reply(), Self.original(by: Self.bob)) == .mismatch)
        #expect(QuoteSettlement.mismatch == QuoteSettlement(check: .mismatch, snippet: "", hasAttachment: false, moderation: .clear))
    }

    /// The quote carries the original's own verdict on its words, still waiting included, and never one the original
    /// inherited from a quote of its own: a reply to a reply hidden only for its quote is not hidden.
    @Test func theQuoteCarriesTheOriginalsOwnVerdictAndNoMore() {
        var flagged = Self.original()
        flagged.moderation = .flagged
        #expect(Self.settlement(Self.reply(), flagged).moderation == .flagged)
        flagged.moderation = .waiting
        #expect(Self.settlement(Self.reply(), flagged).moderation == .waiting)
        var hiddenForItsQuote = Self.original()
        hiddenForItsQuote.quoteModeration = .flagged
        hiddenForItsQuote.replyTo = MessageReply(messageId: "x", authorId: Self.bob.string, author: "", snippet: "")
        #expect(Self.settlement(Self.reply(), hiddenForItsQuote).moderation == .clear)
        flagged.moderation = MessageModeration(rawValue: 9)
        #expect(Self.settlement(Self.reply(), flagged).moderation == .clear, "a verdict this build does not know is clear")
    }

    // MARK: The stores

    /// A settle writes the quote's columns once, while the reply is unchecked, and leaves the rest of the row as it was.
    @Test(arguments: RepositoryKind.allCases)
    func aSettleWritesOnceAndOnlyTheQuote(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        var reply = Self.reply()
        reply.moderation = .flagged
        reply.mentions = [MessageMention(nodeId: Self.ann.string, name: "Ann")]
        store.save(reply)
        store.markDelivered(reply.id)
        let settlement = QuoteSettlement(check: .mismatch, snippet: "", hasAttachment: false, moderation: .clear)
        #expect(store.settleQuote(reply.id, settlement))
        #expect(!store.settleQuote(reply.id, Self.settlement(reply, Self.original())), "once settled, never again")
        let stored = try #require(store.message(reply.id))
        #expect(stored.replyCheck == .mismatch && stored.replyTo?.snippet.isEmpty == true && stored.replyTo?.hasAttachment == false)
        #expect(stored.replyTo?.author == "Anyone" && stored.replyTo?.messageId == "orig", "the claim's ids and name stay a record")
        #expect(stored.moderation == .flagged && stored.delivered && stored.body == "yes" && stored.mentions == reply.mentions)
        #expect(!store.settleQuote("plain-missing", settlement), "nothing to settle")
        // A verified settle whose original is no longer held keeps the verdict it was judged with.
        let orphan = Self.reply("orphan", quoting: "gone")
        store.save(orphan)
        var judged = Self.settlement(orphan, Self.original("gone"))
        judged.moderation = .flagged
        #expect(store.settleQuote(orphan.id, judged))
        #expect(store.message(orphan.id)?.quoteModeration == .flagged)
        store.save(
            MessageRecord(id: "plain", senderId: Self.bob, recipientId: nil, conversationId: Conversations.nearby, body: "", sentAt: 3))
        #expect(!store.settleQuote("plain", settlement), "a row that quotes nothing has no quote to settle")
    }

    /// A verified settle reads the original's verdict as it writes, and the original's screen passes its verdict on to
    /// the replies verified against it, so neither order leaves a quote waiting.
    @Test(arguments: RepositoryKind.allCases)
    func theOriginalsVerdictReachesItsVerifiedReplies(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        var original = Self.original()
        original.moderation = .waiting
        store.save(original)
        let early = Self.reply("early")
        store.save(early)
        // Judged while the original was clear, written once it is waiting: the write reads it.
        let judged = Self.settlement(early, Self.original())
        #expect(store.settleQuote(early.id, judged))
        #expect(store.message(early.id)?.quoteModeration == .waiting)
        #expect(store.setModeration(original.id, to: .flagged))
        #expect(store.message(early.id)?.quoteModeration == .flagged)
        // A reply judged before its insert, whose original's screen landed in between, takes it on the refresh.
        var late = Self.reply("late").settled(with: Self.settlement(Self.reply("late"), original))
        late.quoteModeration = .waiting
        store.save(late)
        #expect(store.refreshQuoteModeration(late.id))
        #expect(store.message(late.id)?.quoteModeration == .flagged)
        #expect(!store.refreshQuoteModeration(late.id), "nothing left to refresh")
        // An unchecked reply waits on its own screen, not the original's.
        var unchecked = Self.reply("unchecked")
        unchecked.quoteModeration = .waiting
        store.save(unchecked)
        store.setModeration(original.id, to: .clear)
        #expect(store.message(unchecked.id)?.quoteModeration == .waiting)
        #expect(store.message(early.id)?.quoteModeration == .clear)
    }

    /// The sender's words are screened only while the quote is unchecked and waiting: a settled quote keeps the
    /// original's verdict, and the screens left to run name only bodies and unchecked quotes.
    @Test(arguments: RepositoryKind.allCases)
    func aQuotesOwnScreenCountsOnlyWhileItIsUnchecked(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        var waiting = Self.reply("waiting", quoting: "absent")
        waiting.quoteModeration = .waiting
        store.save(waiting)
        var settled = Self.reply("settled")
        settled.quoteModeration = .waiting
        store.save(settled)
        store.save(Self.original())
        #expect(store.settleQuote(settled.id, Self.settlement(settled, Self.original())))
        #expect(store.waitingForModeration().map(\.id) == ["waiting"])
        #expect(!store.setQuoteModeration(settled.id, to: .flagged), "a verified quote is the original's to judge")
        #expect(store.setQuoteModeration(waiting.id, to: .flagged))
        #expect(!store.setQuoteModeration(waiting.id, to: .clear), "screened once")
        #expect(store.message(waiting.id)?.quoteModeration == .flagged && store.waitingForModeration().isEmpty)
    }

    /// The replies an original settles as it lands, and the start's backlog: unchecked, somebody else's, and for the
    /// backlog only those whose original is held, each id by its bytes.
    @Test(arguments: RepositoryKind.allCases)
    func theQueriesFindTheRepliesStillToSettle(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(Self.reply("r1"))
        store.save(Self.reply("r2"))
        store.save(Self.reply("ours", from: Self.me))
        store.save(Self.reply("other", quoting: "orig\u{0}"))
        store.save(Self.reply("absent", quoting: "never"))
        #expect(store.repliesAwaiting("orig", me: Self.me, limit: 200).map(\.id) == ["r1", "r2"])
        #expect(store.repliesAwaiting("orig", me: Self.me, limit: 1).map(\.id) == ["r1"])
        #expect(store.unsettledQuotes(me: Self.me, limit: 200).isEmpty, "no original is held yet")
        store.save(Self.original())
        #expect(store.unsettledQuotes(me: Self.me, limit: 200).map(\.id) == ["r1", "r2"])
        store.settleQuote("r1", Self.settlement(Self.reply("r1"), Self.original()))
        #expect(store.repliesAwaiting("orig", me: Self.me, limit: 200).map(\.id) == ["r2"])
        #expect(store.unsettledQuotes(me: Self.me, limit: 200).map(\.id) == ["r2"])
    }

    /// A row stored without the check reads unchecked and clear, and every save keeps what it holds.
    @Test(arguments: RepositoryKind.allCases)
    func aSaveKeepsTheCheck(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let reply = Self.reply().settled(with: Self.settlement(Self.reply(), Self.original()))
        store.save(reply)
        #expect(store.message(reply.id) == reply)
        #expect(store.message(reply.id)?.replyCheck == .verified)
    }
}
