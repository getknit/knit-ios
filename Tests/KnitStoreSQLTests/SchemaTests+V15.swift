import Foundation
import GRDB
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

// Migrations from v15 on test here, so `SchemaTests+V11` stays inside the lint's file length.

extension SchemaTests {
    @Test func v15StartsEveryHeldMessageRead() throws {
        // Nothing kept read state before v15 (ADR 2026-10.frmj): every row held reads as read, so an update shows no
        // count for what the phone held before it, and a message stored after it counts.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v14")
        let bob = fixtureNodeId(2)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (id, senderId, conversationId, body, sentAt, arrivedAt, delivered, pendingKey, kind, moderation)
                    VALUES (?, ?, ?, ?, 3, 3, 0, 0, 0, 0)
                    """,
                arguments: [StoredText.bytes("m1"), StoredText.bytes(bob.string), StoredText.bytes("nearby"), StoredText.bytes("hi")]
            )
        }
        try Schema.migrator.migrate(queue)
        let database = try KnitDatabase(writer: queue, failures: recordFailure)
        let messages = SQLMessageStore(database)
        #expect(messages.unreadCounts(excludingSenders: []).isEmpty)
        messages.save(
            MessageRecord(id: "m2", senderId: bob, recipientId: nil, conversationId: "nearby", body: "hey", sentAt: 4, arrivedAt: 4))
        #expect(messages.unreadCounts(excludingSenders: []) == [ExactKey("nearby"): 1])
        #expect(messages.messages(in: "nearby").map(\.id) == ["m1", "m2"])
    }

    @Test func theUnreadQueriesUseThePartialIndex() throws {
        // `messages_unread` holds only unread rows, which reading keeps few; a query SQLite answers from the whole table
        // instead would read every message held each time the list redraws. Each statement the store runs is planned
        // again here, so the check follows the store's own SQL.
        let statements = Lock<[String]>([])
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace(options: .statement) { event in
                if case .statement(let statement) = event, statement.sql.contains("unread = 1") {
                    statements.withLock { $0.append(statement.sql) }
                }
            }
        }
        let queue = try DatabaseQueue(configuration: configuration)
        let messages = SQLMessageStore(try KnitDatabase(writer: queue, failures: recordFailure))
        statements.withLock { $0.removeAll() } // The migration's own CREATE INDEX.
        messages.save(
            MessageRecord(
                id: "m1", senderId: fixtureNodeId(2), recipientId: nil, conversationId: "nearby", body: "hi", sentAt: 1, arrivedAt: 1))
        _ = messages.unreadCounts(excludingSenders: [fixtureNodeId(3)])
        messages.markRead(in: "nearby")
        let traced = statements.withLock { $0 }
        #expect(traced.count == 2)
        for sql in traced {
            let placeholders = sql.filter { $0 == "?" }.count
            let plan = try queue.read { db in
                try Row.fetchAll(
                    db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: StatementArguments(Array(repeating: Data([0x6e]), count: placeholders))
                ).map { $0["detail"] as String }
            }
            #expect(plan.contains { $0.contains("messages_unread") }, "\(sql): \(plan)")
        }
    }
}
