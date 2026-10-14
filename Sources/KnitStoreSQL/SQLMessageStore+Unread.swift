import GRDB
import KnitStore
public import KnitWire

// Unread, apart from the class only to keep its body inside the lint's length: the `unread` column (schema v15, ADR
// 2026-10.frmj), which ``SQLMessageStore``'s insert sets and nothing but reading clears.
extension SQLMessageStore {
    /// Reads every message of `conversationId` (``MessageStore/markRead(in:)``).
    @discardableResult
    public func markRead(in conversationId: String) -> Bool {
        database.write(or: false) { db in
            // `unread = 1` is written into the SQL, not bound: SQLite uses a partial index only for a term it can see
            // matches the index's own, and `messages_unread` is `WHERE unread = 1`.
            try db.execute(
                sql: "UPDATE messages SET unread = 0 WHERE conversationId = ? AND unread = 1",
                arguments: [StoredText.bytes(conversationId)]
            )
            return db.changesCount > 0
        }
    }

    /// How many unread messages each thread holds (``MessageStore/unreadCounts(excludingSenders:)``).
    public func unreadCounts(excludingSenders blocked: Set<NodeId>) -> [ExactKey: Int] {
        // One pass over `messages_unread`, which holds only unread rows. An empty `NOT IN ()` holds for every row.
        let senders = blocked.sorted().map { StoredText.bytes($0.string) }
        let excluded = Array(repeating: "?", count: senders.count).joined(separator: ", ")
        return database.read(or: [:]) { db in
            var counts: [ExactKey: Int] = [:]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT conversationId, count(*) AS unread FROM messages
                    WHERE unread = 1 AND senderId NOT IN (\(excluded)) GROUP BY conversationId
                    """,
                arguments: StatementArguments(senders)
            )
            for row in rows {
                counts[ExactKey(try row.text("conversationId"))] = try row.decode(Int.self, forColumn: "unread")
            }
            return counts
        }
    }
}
