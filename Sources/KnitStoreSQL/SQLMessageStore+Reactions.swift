import GRDB
public import KnitStore
public import KnitWire

// Reactions, apart from the class only to keep its body inside the lint's length: the `reactions` table
// (`ReactionDao.kt` in knit-next), keyed by the message's frame id and the reactor's node id, both by their bytes.
extension SQLMessageStore {
    /// Stores `reaction` when it is strictly newer than the one held, in one statement (``MessageStore/applyReaction(_:)``).
    @discardableResult
    public func applyReaction(_ reaction: ReactionRecord) -> Bool {
        database.write(or: false) { db in
            let message = StoredText.bytes(reaction.messageId)
            let deleted = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM deleted_messages WHERE id = ?)", arguments: [message])
            guard deleted != true else {
                return false
            }
            // The update's WHERE keeps a tie or an older update out, so nothing changes and `changesCount` reads 0.
            try db.execute(
                sql: """
                    INSERT INTO reactions (messageId, reactor, emoji, updatedAt) VALUES (?, ?, ?, ?)
                    ON CONFLICT (messageId, reactor) DO UPDATE SET emoji = excluded.emoji, updatedAt = excluded.updatedAt
                    WHERE excluded.updatedAt > reactions.updatedAt
                    """,
                arguments: [message, StoredText.bytes(reaction.reactor.string), StoredText.bytes(reaction.emoji), reaction.updatedAt]
            )
            return db.changesCount > 0
        }
    }

    /// The reaction `reactor` holds on `messageId`, a retraction included (``MessageStore/reaction(on:by:)``).
    public func reaction(on messageId: String, by reactor: NodeId) -> ReactionRecord? {
        database.read(or: nil) { db in
            try Row.fetchOne(
                db,
                sql: "SELECT messageId, reactor, emoji, updatedAt FROM reactions WHERE messageId = ? AND reactor = ?",
                arguments: [StoredText.bytes(messageId), StoredText.bytes(reactor.string)]
            ).map(Self.reaction)
        }
    }

    /// The reactions standing on a thread's ordinary messages, oldest first (``MessageStore/reactions(in:)``). A BLOB
    /// orders by `memcmp`, so the ties fall in the order the memory store's byte comparison gives.
    public func reactions(in conversationId: String) -> [ReactionRecord] {
        database.read(or: []) { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT r.messageId, r.reactor, r.emoji, r.updatedAt FROM reactions AS r
                    JOIN messages AS m ON m.id = r.messageId
                    WHERE m.conversationId = ? AND m.kind = 0 AND r.emoji IS NOT NULL
                    ORDER BY r.updatedAt, r.messageId, r.reactor
                    """,
                arguments: [StoredText.bytes(conversationId)]
            ).map(Self.reaction)
        }
    }

    /// Forgets the old reactions whose message is not held (``MessageStore/pruneOrphanReactions(updatedBefore:)``).
    public func pruneOrphanReactions(updatedBefore cutoff: Int64) {
        database.write(or: ()) { db in
            try db.execute(
                sql: "DELETE FROM reactions WHERE updatedAt < ? AND messageId NOT IN (SELECT id FROM messages)",
                arguments: [cutoff]
            )
        }
    }

    /// The reaction in a row of `messageId, reactor, emoji, updatedAt`.
    private static func reaction(_ row: Row) throws -> ReactionRecord {
        ReactionRecord(
            messageId: try row.text("messageId"),
            reactor: try row.nodeId("reactor"),
            emoji: try row.optionalText("emoji"),
            updatedAt: try row.decode(Int64.self, forColumn: "updatedAt")
        )
    }
}
