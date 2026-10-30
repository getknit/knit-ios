import GRDB
public import KnitStore

// What the content filter made of a message's words (ADR 2026-10.e4kz), apart so the store's class stays inside the
// lint's length.
extension SQLMessageStore {
    /// Records the filter's verdict on message `id`'s words, and passes it to the replies verified against it
    /// (``MessageStore/setModeration(_:to:)``).
    @discardableResult
    public func setModeration(_ id: String, to moderation: MessageModeration) -> Bool {
        database.write(or: false) { db in
            let key = StoredText.bytes(id)
            try db.execute(
                sql: "UPDATE messages SET moderation = ? WHERE id = ? AND moderation != ?",
                arguments: [moderation.rawValue, key, moderation.rawValue]
            )
            guard db.changesCount > 0 else {
                return false
            }
            // The replies whose quote of it was verified carry its verdict (``MessageModeration/ofQuote``), in the same
            // transaction, so a reply settling meanwhile reads the old verdict or sees this one.
            try db.execute(
                sql: "UPDATE messages SET replyToFlagged = ? WHERE replyToId = ? AND replyCheck = \(QuoteCheck.verified.rawValue)",
                arguments: [moderation.ofQuote.rawValue, key]
            )
            return true
        }
    }

    /// The messages whose words, or whose unchecked quote's words, wait for the filter
    /// (``MessageStore/waitingForModeration()``).
    public func waitingForModeration() -> [MessageRecord] {
        database.read(or: []) { db in
            // The codes are written into the SQL, not bound: SQLite uses a partial index only for a term it can see
            // matches the index's own, and `messages_waiting` is `WHERE moderation = 2`, `messages_quoteWaiting`
            // `WHERE replyToFlagged = 2 AND replyCheck = 0`.
            let waiting = MessageModeration.waiting.rawValue
            let unchecked = QuoteCheck.unchecked.rawValue
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.columns) FROM messages WHERE seq IN (
                        SELECT seq FROM messages WHERE moderation = \(waiting)
                        UNION SELECT seq FROM messages WHERE replyToFlagged = \(waiting) AND replyCheck = \(unchecked)
                    )
                    ORDER BY seq
                    """
            ).map(Self.record)
        }
    }
}
