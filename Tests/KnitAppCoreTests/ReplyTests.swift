import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Quoted replies on the screens (ADR 2026-10.mn29): the quote the composer writes, as `ChatScreen.kt:1352-1388` does,
/// how a thread shows one, and the content filter reading a quote with its reply.
@MainActor
@Suite struct ReplyTests {
    private let sam = AppRig.sam
    private let priya = AppRig.priya
    private let stranger = AppRig.stranger
    private static let threat = "I will find you"

    /// A rig whose filter flags ``threat`` and passes the rest.
    private static func screened() -> AppRig {
        let classifier = FakeTextClassifier([threat: FakeTextClassifier.scores("threat", 0.95)])
        return AppRig(screening: TextScreening(classifier: classifier, words: WordFilter(words: []), slurs: WordFilter(words: [])))
    }

    /// Stores `record` as the engine would and tells the session.
    private func arrive(_ record: MessageRecord, in rig: AppRig) async {
        rig.stores.messages.save(record)
        await rig.session.handle(.received(record, isRequest: false))
    }

    private func photo(_ id: String, mime: String, name: String? = nil, animated: Bool = false) -> MessageRecord {
        let hash = BlobHash(String(repeating: "c", count: 64)) ?? .empty
        let dimensions = PhotoDimensions(width: 4, height: 3, animated: animated)
        return MessageRecord(
            id: id,
            senderId: sam.nodeId,
            recipientId: nil,
            conversationId: Conversations.nearby,
            body: "",
            sentAt: 1000,
            attachment: MessageAttachment(hash: hash, mime: mime, name: name, dimensions: name == nil ? dimensions : nil)
        )
    }

    // MARK: Writing a quote

    @Test func aReplyQuotesTheAuthorsOwnNameAndTheirWordsOnOneLine() async throws {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        let post = await rig.receive("  Meet   at\nthe gate ", from: sam.nodeId)
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        thread.reply(to: try #require(thread.state.messages.first))
        let held = try #require(thread.replying)
        #expect(held.reply == MessageReply(messageId: post.id, authorId: sam.nodeId.string, author: "Sam", snippet: "Meet at the gate"))
        #expect(held.quote.author == "Sam" && held.quote.line == "Meet at the gate")
        #expect(thread.repliesStarted == 1)
    }

    /// Our own name goes on the wire, never "You", which each phone writes for its own (`ChatViewModel.kt:1806-1818`).
    @Test func quotingOurselvesSendsOurNameAndShowsYou() async throws {
        let rig = AppRig()
        await rig.session.send("Gate 3", in: Conversations.nearby)
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        thread.reply(to: try #require(thread.state.messages.first))
        #expect(thread.replying?.reply.author == Alias.alias(for: rig.me.string), "with no name, the alias")
        #expect(thread.replying?.quote.author == Copy.Common.you)
        await rig.session.updateProfile(name: "Maya", status: "", openToChat: true)
        thread.reply(to: try #require(thread.state.messages.first))
        #expect(thread.replying?.reply.author == "Maya")
    }

    /// A tap would have had to show them, so a quote never does (`buildReplySnippet`'s `flagged`).
    @Test func wordsTheFilterHidesStayOutOfTheQuote() async throws {
        let rig = Self.screened()
        await rig.receive(Self.threat, from: sam.nodeId)
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        thread.reply(to: try #require(thread.state.messages.first))
        #expect(thread.replying?.reply.snippet.isEmpty == true)
        rig.session.filtersContent = false
        thread.reply(to: try #require(thread.state.messages.first))
        #expect(thread.replying?.reply.snippet == Self.threat)
    }

    /// The wire says only that there was an attachment, so a GIF, a file or a voice note is named in the snippet; a still
    /// photo leaves its label to the receiver.
    @Test func anAttachmentWithoutWordsIsNamedOrLeftToTheReceiver() async {
        let rig = AppRig()
        await arrive(photo("gif", mime: "image/webp", animated: true), in: rig)
        await arrive(photo("file", mime: "application/pdf", name: "plan.pdf"), in: rig)
        await arrive(photo("still", mime: "image/jpeg"), in: rig)
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        let quotes = thread.state.messages.map { message -> MessageReply? in
            thread.reply(to: message)
            return thread.replying?.reply
        }
        #expect(quotes.map(\.?.snippet) == [Copy.Attachments.gifPreview, Copy.Attachments.filePreview("plan.pdf"), ""])
        #expect(quotes.allSatisfy { $0?.hasAttachment == true })
        #expect(thread.replying?.quote.line == Copy.Attachments.photoPreview)
    }

    // MARK: The composer

    @Test func sendCarriesTheQuoteAndPutsItAway() async throws {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        rig.stores.conversations.accept(sam.nodeId.string)
        let dm = await rig.receive("North gate?", from: sam.nodeId, to: rig.me)
        let thread = ChatModel(conversationId: sam.nodeId.string, session: rig.session)
        thread.reply(to: try #require(thread.state.messages.first))
        let quote = try #require(thread.replying?.reply)
        thread.draft = "Yes, by the tent"
        await thread.send()
        let sent = try #require(rig.stores.messages.messages(in: sam.nodeId.string).last)
        #expect(sent.body == "Yes, by the tent" && sent.replyTo == quote && quote.messageId == dm.id)
        #expect(thread.replying == nil)
        #expect(thread.state.messages.last?.quote?.jumps == true, "the original is in the thread")
    }

    /// The room refuses abusive words before anything is sent, and the quote stays with the draft.
    @Test func aRefusedSendKeepsTheQuote() async throws {
        let rig = Self.screened()
        await rig.receive("Lunch?", from: sam.nodeId)
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        thread.reply(to: try #require(thread.state.messages.first))
        thread.draft = Self.threat
        await thread.send()
        #expect(thread.wordsRefused && thread.replying != nil)
        thread.cancelReply()
        #expect(thread.replying == nil)
    }

    @Test func noReplyStartsWhereThereIsNoComposer() async throws {
        let rig = AppRig()
        await rig.receive("Hi! Blue tent?", from: stranger.nodeId, to: rig.me)
        let request = ChatModel(conversationId: stranger.nodeId.string, session: rig.session)
        #expect(!request.state.canReply)
        request.reply(to: try #require(request.state.messages.first))
        #expect(request.replying == nil && request.repliesStarted == 0)
        let group = await rig.group([sam], createdBy: sam, departed: [priya])
        let thread = ChatModel(conversationId: group.id, session: rig.session)
        let notice = try #require(thread.state.messages.first { $0.notice != nil })
        thread.reply(to: notice)
        #expect(thread.replying == nil, "a status line takes no reply")
    }

    // MARK: Showing a quote

    /// The replier names the author, but a name is free text: a peer this phone knows shows under its own label.
    @Test func aQuoteNamesTheAuthorAsThisPhoneDoes() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya")
        let named = { (author: NodeId, name: String) in
            MessageReply(messageId: "m0", authorId: author.string, author: name, snippet: "hi")
        }
        await rig.receive("a", from: sam.nodeId, sentAt: 1, replyTo: named(priya.nodeId, "Pree"))
        await rig.receive("b", from: sam.nodeId, sentAt: 2, replyTo: named(rig.me, "Maya"))
        await rig.receive("c", from: sam.nodeId, sentAt: 3, replyTo: named(stranger.nodeId, "Blue tent"))
        await rig.receive("d", from: sam.nodeId, sentAt: 4, replyTo: named(stranger.nodeId, " "))
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(
            thread.state.messages.map(\.quote?.author) == [
                "Priya", Copy.Common.you, "Blue tent", Alias.alias(for: stranger.nodeId.string),
            ])
    }

    /// A photo quoted without words shows the receiver's own label (`chat_reply_photo`); a quote with nothing to show
    /// shows its author alone.
    @Test func aWordlessQuoteShowsThePhotosLabelOrNothing() async {
        let rig = AppRig()
        let photo = MessageReply(messageId: "m0", authorId: sam.nodeId.string, author: "Sam", snippet: "", hasAttachment: true)
        let bare = MessageReply(messageId: "m1", authorId: sam.nodeId.string, author: "Sam", snippet: "")
        await rig.receive("a", from: sam.nodeId, sentAt: 1, replyTo: photo)
        await rig.receive("b", from: sam.nodeId, sentAt: 2, replyTo: bare)
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(thread.state.messages.map(\.quote?.line) == [Copy.Attachments.photoPreview, nil])
    }

    /// A blocked person's words stay out of sight, quoted by someone else as much as their own (ADR 2026-10.5wgg).
    @Test func aQuoteOfSomeoneBlockedShowsNoneOfTheirWords() async throws {
        let rig = AppRig()
        let original = await rig.receive("Meet me alone", from: priya.nodeId, sentAt: 1)
        let quote = MessageReply(messageId: original.id, authorId: priya.nodeId.string, author: "Priya", snippet: "Meet me alone")
        await rig.receive("No thanks", from: sam.nodeId, sentAt: 2, replyTo: quote)
        await rig.session.block(priya.nodeId)
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        let shown = try #require(thread.state.messages.last?.quote)
        #expect(shown.blocked && shown.line == Copy.Replies.blockedQuote && !shown.jumps)
        await rig.session.unblock(priya.nodeId)
        #expect(thread.state.messages.last?.quote?.line == "Meet me alone")
    }

    /// A quote takes the thread only to an original the thread shows.
    @Test func aQuoteJumpsOnlyToAnOriginalTheThreadShows() async {
        let rig = AppRig()
        let original = await rig.receive("Lunch?", from: priya.nodeId, sentAt: 1)
        let elsewhere = await rig.receive("Private", from: priya.nodeId, to: rig.me, sentAt: 2)
        let quote = { (id: String) in MessageReply(messageId: id, authorId: priya.nodeId.string, author: "Priya", snippet: "x") }
        await rig.receive("Yes", from: sam.nodeId, sentAt: 3, replyTo: quote(original.id))
        await rig.receive("Hm", from: sam.nodeId, sentAt: 4, replyTo: quote(elsewhere.id))
        await rig.receive("?", from: sam.nodeId, sentAt: 5, replyTo: quote("never-held"))
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(thread.state.messages.compactMap(\.quote?.jumps) == [true, false, false])
        await rig.session.deleteMessage(original.id)
        #expect(thread.state.messages.compactMap(\.quote?.jumps) == [false, false, false])
    }

    // MARK: The filter

    /// A quote is someone's words too: either the reply's words or its quote flags it, and one tap shows both.
    @Test func aFlaggedQuoteHidesItsReply() async {
        let rig = Self.screened()
        let flagged = MessageReply(messageId: "m0", authorId: priya.nodeId.string, author: "Priya", snippet: Self.threat)
        let worded = await rig.receive("see you there", from: sam.nodeId, sentAt: 1, replyTo: flagged)
        let wordless = await rig.receive("", from: sam.nodeId, sentAt: 2, replyTo: flagged)
        let fine = MessageReply(messageId: "m1", authorId: priya.nodeId.string, author: "Priya", snippet: "lunch?")
        let clear = await rig.receive("yes", from: sam.nodeId, sentAt: 3, replyTo: fine)
        #expect([worded, wordless, clear].map { rig.stores.messages.message($0.id)?.moderation } == [.flagged, .flagged, .clear])
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(thread.state.messages.map(\.hiddenWords) == [.flagged, .flagged, nil])
    }

    /// A report of a reply carries what it quoted, as the reply carried it, whatever this phone hides of it.
    @Test func aReportOfAReplyCarriesItsQuote() async throws {
        let rig = AppRig()
        await rig.pin(priya, name: "Priya")
        let quote = MessageReply(messageId: "m0", authorId: priya.nodeId.string, author: "Pree", snippet: "Lunch?")
        await rig.receive("No", from: sam.nodeId, replyTo: quote)
        let thread = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        let reply = try #require(thread.state.messages.first)
        let report = try #require(thread.reporting(reply))
        #expect(report.quote == AbuseReport.Quote(author: "Priya", words: "Lunch?"))
        let email = ReportEmail(report, version: "1.0", now: Date(milliseconds: 0))
        #expect(email.body.contains(Copy.Report.emailQuote("Priya", "Lunch?")))
    }
}
