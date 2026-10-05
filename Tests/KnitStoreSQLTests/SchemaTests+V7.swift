import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

// Migrations after v6 test here, so `SchemaTests` stays inside the lint's file length.

extension SchemaTests {
    @Test func v7ShowsEveryMessageAsItWas() throws {
        // Nothing was screened before v7 (ADR 2026-10.e4kz): every stored message reads as passed, none waits, and
        // a save after the migration keeps what the filter made of it.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v6")
        let bob = fixtureNodeId(2)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (id, senderId, conversationId, body, sentAt, delivered, pendingKey, kind)
                    VALUES (?, ?, ?, ?, 3, 0, 0, 0)
                    """,
                arguments: [StoredText.bytes("m1"), StoredText.bytes(bob.string), StoredText.bytes("nearby"), StoredText.bytes("hi")]
            )
        }
        let database = try KnitDatabase(writer: queue, failures: recordFailure)
        let messages = SQLMessageStore(database)
        #expect(messages.message("m1")?.moderation == MessageModeration.clear)
        #expect(messages.waitingForModeration().isEmpty)
        #expect(messages.setModeration("m1", to: .flagged))
        #expect(messages.message("m1")?.moderation == .flagged)
    }

    @Test func v8RemembersNoDeletionAndKeepsEveryMessage() throws {
        // Nothing was deleted before v8 (ADR 2026-10.u7cq): every stored message reads as it was, and its id is held
        // only by its row.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v7")
        let bob = fixtureNodeId(2)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (id, senderId, conversationId, body, sentAt, delivered, pendingKey, kind, moderation)
                    VALUES (?, ?, ?, ?, 3, 0, 0, 0, 0)
                    """,
                arguments: [StoredText.bytes("m1"), StoredText.bytes(bob.string), StoredText.bytes("nearby"), StoredText.bytes("hi")]
            )
        }
        let database = try KnitDatabase(writer: queue, failures: recordFailure)
        let messages = SQLMessageStore(database)
        #expect(messages.message("m1")?.body == "hi")
        #expect(messages.contains("m1") && !messages.contains("m2"))
        #expect(messages.deleteMessage("m1", at: 4)?.id == "m1")
        let again = MessageRecord(id: "m1", senderId: bob, recipientId: nil, conversationId: "nearby", body: "hi", sentAt: 3)
        #expect(messages.contains("m1") && !messages.insertIfAbsent(again), "the new table remembers it")
    }
}
