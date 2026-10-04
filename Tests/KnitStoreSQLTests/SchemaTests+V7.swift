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
}
