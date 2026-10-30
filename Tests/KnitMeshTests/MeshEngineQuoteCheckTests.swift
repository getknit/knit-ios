import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A received quote judged against the original it names (knit-next ADR 2026-10.gpa3), through the engine:
/// `InboundPipelineTest`'s reply cases and `QuoteVerifierTest` at knit-next `7439fd9cc`.
@Suite struct MeshEngineQuoteCheckTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let start = EngineFixture.start

    private func fixture(stores: MeshStores = .inMemory(), started: Bool = true) throws -> EngineFixture {
        let configuration = MeshConfiguration { _ in "📎 file" }
        let fixture = EngineFixture(alice, stores: stores, configuration: configuration, started: started)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        try fixture.pin(carol)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        return fixture
    }

    /// Carol's post in the room, `body`, under the frame id `label` names.
    private func carolPosts(_ label: String, _ body: String, in fixture: EngineFixture, at offset: Int64 = 0) throws {
        fixture.deliver(try carol.roomPost(body, id: frameIdOf(label), sentAt: start + offset), from: carol)
    }

    /// Bob's room reply, quoting the frame `quoted` names by `author` with the words he claims.
    private func bobReplies(
        _ label: String, quoting quoted: String, by author: TestPeer, claiming snippet: String, in fixture: EngineFixture,
        at offset: Int64 = 1
    ) throws {
        let ref = ReplyRef(
            messageId: frameIdOf(quoted), authorId: author.nodeId.string, author: "Ann", snippet: snippet, hasAttachment: true)
        fixture.deliver(
            try bob.roomPost("", id: frameIdOf(label), sentAt: start + offset, content: ChatContent(body: "yes", replyTo: ref)), from: bob)
    }

    private func stored(_ label: String, in fixture: EngineFixture) throws -> MessageRecord {
        try #require(fixture.stores.messages.message(frameIdOf(label)))
    }

    // MARK: Before the insert

    /// A forged snippet over an original this phone holds is rebuilt from the original, words, attachment flag and all, and
    /// the announced row is the rebuilt one.
    @Test func aForgedSnippetOverAHeldOriginalIsRebuilt() throws {
        let fixture = try fixture()
        try carolPosts("o1", "  lunch\nat noon ", in: fixture)
        _ = fixture.engine.drainEvents()
        try bobReplies("q1", quoting: "o1", by: carol, claiming: "I will find you", in: fixture)
        let reply = try stored("q1", in: fixture)
        #expect(reply.replyCheck == .verified && reply.replyTo?.snippet == "lunch at noon" && reply.replyTo?.hasAttachment == false)
        #expect(reply.quoteModeration == .waiting, "the original's words have not been screened yet")
        #expect(announced(fixture.engine.drainEvents()).map(\.record.replyCheck) == [.verified])
    }

    /// A quote that names a held message by the wrong author, or one in another thread, keeps nothing of its claim.
    @Test func aWrongAuthorOrAWrongThreadIsAMismatch() throws {
        let fixture = try fixture()
        try carolPosts("o1", "lunch", in: fixture)
        try bobReplies("q1", quoting: "o1", by: bob, claiming: "lunch", in: fixture)
        let dm = MessageContent(body: "private")
        fixture.deliver(try carol.directMessage("", to: alice, id: frameIdOf("d1"), sentAt: start, content: dm), from: carol)
        try bobReplies("q2", quoting: "d1", by: carol, claiming: "private", in: fixture, at: 2)
        for label in ["q1", "q2"] {
            let reply = try stored(label, in: fixture)
            #expect(
                reply.replyCheck == .mismatch && reply.replyTo?.snippet.isEmpty == true && reply.replyTo?.hasAttachment == false, "\(label)"
            )
            #expect(reply.quoteModeration == .clear)
        }
    }

    // MARK: After the insert

    /// A reply that lands before its original is kept unchecked, its words waiting for the filter; the original settles it
    /// as it lands, replacing the screen's verdict with its own.
    @Test func aReplyAheadOfItsOriginalSettlesWhenTheOriginalLands() throws {
        let fixture = try fixture()
        try bobReplies("q1", quoting: "o1", by: carol, claiming: "forged", in: fixture)
        var reply = try stored("q1", in: fixture)
        #expect(reply.replyCheck == .unchecked && reply.replyTo?.snippet == "forged" && reply.quoteModeration == .waiting)
        fixture.stores.messages.setQuoteModeration(reply.id, to: .flagged)
        try carolPosts("o1", "lunch", in: fixture)
        reply = try stored("q1", in: fixture)
        #expect(reply.replyCheck == .verified && reply.replyTo?.snippet == "lunch" && reply.quoteModeration == .waiting)
        fixture.stores.messages.setModeration(frameIdOf("o1"), to: .clear)
        #expect(try stored("q1", in: fixture).quoteModeration == .clear, "the original's screen reaches its reply")
    }

    /// A reply judged before its insert takes the original's screen that landed in between: the after-insert refresh.
    @Test func aScreenBetweenTheJudgingAndTheInsertIsNotLost() throws {
        let fixture = try fixture()
        try carolPosts("o1", "lunch", in: fixture)
        try bobReplies("q1", quoting: "o1", by: carol, claiming: "lunch", in: fixture)
        // As if the screen had landed between the judging and the insert, which no single-threaded test can interleave.
        var reply = try stored("q1", in: fixture)
        fixture.stores.messages.setModeration(frameIdOf("o1"), to: .flagged)
        reply.quoteModeration = .waiting
        fixture.stores.messages.save(reply)
        #expect(fixture.engine.settleQuotes(after: reply)?.quoteModeration == .flagged)
    }

    /// An original that commits between a reply's judging and its insert is found after the insert: the reply's own check.
    @Test func anOriginalThatRacedInIsFoundAfterTheInsert() throws {
        let fixture = try fixture()
        try carolPosts("o1", "lunch", in: fixture)
        let claim = MessageReply(messageId: frameIdOf("o1"), authorId: carol.nodeId.string, author: "", snippet: "forged")
        let unchecked = MessageRecord(
            id: "late",
            senderId: bob.nodeId,
            recipientId: nil,
            conversationId: Conversations.nearby,
            body: "yes",
            sentAt: start + 1,
            replyTo: claim
        )
        fixture.stores.messages.save(unchecked)
        let settled = try #require(fixture.engine.settleQuotes(after: unchecked))
        #expect(settled.replyCheck == .verified && settled.replyTo?.snippet == "lunch")
    }

    /// Our own replies are never judged or rewritten: we quoted a row we held.
    @Test func ourOwnRepliesAreUntouched() throws {
        let fixture = try fixture()
        try carolPosts("o1", "lunch", in: fixture)
        let quote = MessageReply(messageId: frameIdOf("o1"), authorId: carol.nodeId.string, author: "Carol", snippet: "lunch!")
        let ours = try #require(fixture.engine.postToRoom("yes", replyTo: quote))
        let held = try #require(fixture.stores.messages.message(ours.id))
        #expect(held.replyCheck == .unchecked && held.replyTo == quote && held.quoteModeration == .clear)
        // Nor does the start's backlog touch one.
        _ = EngineFixture(alice, stores: fixture.stores)
        #expect(fixture.stores.messages.message(ours.id) == held)
    }

    /// A quote rebuilt from an original with no words carries the reader's label for what it carried: here a file Carol
    /// sent in our DM, which she then quotes herself.
    @Test func aRebuiltQuoteNamesAFileByTheReadersLabel() throws {
        let fixture = try fixture()
        let file = MessageContent(
            body: "",
            attachmentHash: String(repeating: "b", count: 64),
            attachmentMime: "application/pdf",
            attachmentKey: "aw==",
            attachmentName: "plan.pdf",
            attachmentSize: 10
        )
        fixture.deliver(try carol.directMessage("", to: alice, id: frameIdOf("o1"), sentAt: start, content: file), from: carol)
        let ref = ReplyRef(messageId: frameIdOf("o1"), authorId: carol.nodeId.string, author: "Carol", snippet: "")
        let reply = MessageContent(body: "this one", replyTo: ref)
        fixture.deliver(try carol.directMessage("", to: alice, id: frameIdOf("q1"), sentAt: start + 1, content: reply), from: carol)
        let stored = try stored("q1", in: fixture)
        #expect(stored.replyCheck == .verified && stored.replyTo?.snippet == "📎 file" && stored.replyTo?.hasAttachment == true)
    }

    /// Without the app's labels, as in knit-peer, a quote rebuilt from a wordless original carries no words.
    @Test func withoutLabelsAWordlessOriginalIsQuotedWithNone() {
        #expect(MeshConfiguration().quoteLabel(MessageAttachment(hash: .empty, mime: "audio/mp4")) == nil)
    }

    // MARK: The backlog

    /// Replies stored before the check, whose original is held, settle at the next start; one whose original is not held,
    /// and our own, stay as they were.
    @Test func theBacklogSettlesAtStart() throws {
        let stores = MeshStores.inMemory()
        let original = MessageRecord(
            id: "o1", senderId: carol.nodeId, recipientId: nil, conversationId: Conversations.nearby, body: "lunch", sentAt: start
        )
        let author = carol.nodeId
        let claim = { (id: String, quoted: String, sender: NodeId) in
            MessageRecord(
                id: id,
                senderId: sender,
                recipientId: nil,
                conversationId: Conversations.nearby,
                body: "yes",
                sentAt: start + 1,
                replyTo: MessageReply(messageId: quoted, authorId: author.string, author: "Ann", snippet: "forged")
            )
        }
        stores.messages.save(original)
        stores.messages.save(claim("old", "o1", bob.nodeId))
        stores.messages.save(claim("orphan", "never", bob.nodeId))
        stores.messages.save(claim("ours", "o1", alice.nodeId))
        _ = try fixture(stores: stores)
        #expect(stores.messages.message("old")?.replyCheck == .verified && stores.messages.message("old")?.replyTo?.snippet == "lunch")
        #expect(stores.messages.message("orphan")?.replyCheck == .unchecked)
        #expect(stores.messages.message("ours")?.replyCheck == .unchecked && stores.messages.message("ours")?.replyTo?.snippet == "forged")
    }

    /// An original that lands with more than a batch of replies waiting on it settles them all, a batch at a time.
    @Test func anOriginalSettlesEveryBatchOfRepliesWaitingOnIt() throws {
        let fixture = try fixture()
        for index in 0..<250 {
            let quote = MessageReply(messageId: frameIdOf("o1"), authorId: carol.nodeId.string, author: "", snippet: "forged")
            fixture.stores.messages.save(
                MessageRecord(
                    id: "r\(index)",
                    senderId: bob.nodeId,
                    recipientId: nil,
                    conversationId: Conversations.nearby,
                    body: "",
                    sentAt: start,
                    replyTo: quote
                ))
        }
        try carolPosts("o1", "lunch", in: fixture)
        #expect(fixture.stores.messages.repliesAwaiting(frameIdOf("o1"), me: alice.nodeId, limit: 1000).isEmpty)
        #expect(fixture.stores.messages.message("r249")?.replyTo?.snippet == "lunch")
    }

    /// The backlog works in batches of 200, at most 50 a start, and the next start takes the rest.
    @Test func theBacklogIsBoundedPerStart() throws {
        let stores = MeshStores.inMemory()
        stores.messages.save(
            MessageRecord(
                id: "o1", senderId: carol.nodeId, recipientId: nil, conversationId: Conversations.nearby, body: "x", sentAt: start))
        for index in 0..<450 {
            let quote = MessageReply(messageId: "o1", authorId: carol.nodeId.string, author: "", snippet: "")
            stores.messages.save(
                MessageRecord(
                    id: "r\(index)",
                    senderId: bob.nodeId,
                    recipientId: nil,
                    conversationId: Conversations.nearby,
                    body: "",
                    sentAt: start,
                    replyTo: quote
                ))
        }
        _ = try fixture(stores: stores)
        #expect(stores.messages.unsettledQuotes(me: alice.nodeId, limit: 1000).isEmpty, "three batches, the last short")
        #expect(MeshEngine.quoteBatch == 200 && MeshEngine.quoteBacklogBatches == 50)
    }
}
