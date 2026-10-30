import Foundation
import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

// Migrations from v20 on test here, so `SchemaTests+V18` stays small.

extension SchemaTests {
    @Test func v20StartsEveryHeldReplyUncheckedAndUnflagged() throws {
        // Nothing checked a quote before v20 (knit-next ADR 2026-10.gpa3): a reply held reads unchecked with its words as
        // they came and nothing flagged in them, and the start's backlog finds it once its original is held.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v19")
        let ann = fixtureNodeId(3)
        let bob = fixtureNodeId(2)
        try queue.write { db in
            try Self.insertV19(db, id: "o1", sender: ann, quoting: nil)
            try Self.insertV19(db, id: "r1", sender: bob, quoting: (id: "o1", author: ann))
        }
        try Schema.migrator.migrate(queue)
        let messages = SQLMessageStore(try KnitDatabase(writer: queue, failures: recordFailure))
        let held = try #require(messages.message("r1"))
        #expect(held.replyCheck == .unchecked && held.quoteModeration == .clear && held.moderation == .flagged)
        #expect(held.replyTo == MessageReply(messageId: "o1", authorId: ann.string, author: "Ann", snippet: "forged", hasAttachment: true))
        #expect(messages.message("o1")?.replyCheck == .unchecked && messages.message("o1")?.replyTo == nil)
        #expect(messages.unsettledQuotes(me: fixtureNodeId(1), limit: 200).map(\.id) == ["r1"])
        #expect(messages.waitingForModeration().isEmpty)
    }

    /// A flagged message in the room as v19 stored it, quoting `quoted`'s id by its author when it names one.
    private static func insertV19(_ db: Database, id: String, sender: NodeId, quoting quoted: (id: String, author: NodeId)?) throws {
        try db.execute(
            sql: """
                INSERT INTO messages (id, senderId, conversationId, body, sentAt, arrivedAt, delivered, pendingKey, kind,
                    moderation, replyToId, replyToAuthorId, replyToAuthor, replyToSnippet, replyToHasAttachment)
                VALUES (?, ?, ?, ?, 3, 3, 0, 0, 0, 1, ?, ?, ?, ?, 1)
                """,
            arguments: [
                StoredText.bytes(id), StoredText.bytes(sender.string), StoredText.bytes(Conversations.nearby), StoredText.bytes("words"),
                StoredText.bytes(quoted?.id), StoredText.bytes(quoted?.author.string), StoredText.bytes(quoted.map { _ in "Ann" }),
                StoredText.bytes(quoted.map { _ in "forged" }),
            ]
        )
    }

    @Test func theQuoteQueriesUseTheirPartialIndexes() throws {
        let database = try KnitDatabase.inMemory(failures: recordFailure)
        try database.writer.read { db in
            let awaiting = try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN SELECT seq FROM messages WHERE replyToId = x'00' AND replyCheck = 0"
            ).map { $0["detail"] as String }
            #expect(awaiting.joined().contains("messages_replyToId"), "\(awaiting)")
            let waiting = try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN SELECT seq FROM messages WHERE replyToFlagged = 2 AND replyCheck = 0"
            ).map { $0["detail"] as String }
            #expect(waiting.joined().contains("messages_quoteWaiting"), "\(waiting)")
        }
    }
}
