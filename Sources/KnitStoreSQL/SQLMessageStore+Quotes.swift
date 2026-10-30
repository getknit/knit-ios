import GRDB
public import KnitStore
public import KnitWire

// A reply's quote checked against its original (knit-next ADR 2026-10.gpa3), apart so the store stays inside the lint's
// length. Each write touches the quote's columns alone: a whole-row save would undo a tick, a verdict or a photo's size
// written in between (`MessageDao.applyQuoteVerdict`).
extension SQLMessageStore {
    /// The original's verdict as a quote of it carries it, written into the SQL: flagged and waiting pass, and anything
    /// else, a code this build does not know included, reads as clear (``KnitStore/MessageModeration/ofQuote``).
    /// `NULL` when the original is not held.
    private static let originalVerdict = """
        SELECT CASE o.moderation \
        WHEN \(MessageModeration.flagged.rawValue) THEN \(MessageModeration.flagged.rawValue) \
        WHEN \(MessageModeration.waiting.rawValue) THEN \(MessageModeration.waiting.rawValue) \
        ELSE \(MessageModeration.clear.rawValue) END \
        FROM messages AS o WHERE o.id = messages.replyToId
        """

    /// Records the filter's verdict on reply `id`'s unchecked quote (``MessageStore/setQuoteModeration(_:to:)``).
    @discardableResult
    public func setQuoteModeration(_ id: String, to moderation: MessageModeration) -> Bool {
        let waiting = MessageModeration.waiting.rawValue
        return database.write(or: false) { db in
            try db.execute(
                sql: """
                    UPDATE messages SET replyToFlagged = ?
                    WHERE id = ? AND replyToId IS NOT NULL AND replyCheck = \(QuoteCheck.unchecked.rawValue)
                        AND replyToFlagged = \(waiting) AND ? != \(waiting)
                    """,
                arguments: [moderation.rawValue, StoredText.bytes(id), moderation.rawValue]
            )
            return db.changesCount > 0
        }
    }

    /// Writes reply `id`'s settled quote, once (``MessageStore/settleQuote(_:_:)``).
    @discardableResult
    public func settleQuote(_ id: String, _ settlement: QuoteSettlement) -> Bool {
        // A verified quote reads its verdict from the original in the statement that writes it, so the original's screen
        // either landed before and is read, or lands after and passes it on (``setModeration(_:to:)``).
        let verdict = settlement.check == .verified ? "coalesce((\(Self.originalVerdict)), ?)" : "?"
        return database.write(or: false) { db in
            try db.execute(
                sql: """
                    UPDATE messages SET replyCheck = ?, replyToSnippet = ?, replyToHasAttachment = ?, replyToFlagged = \(verdict)
                    WHERE id = ? AND replyToId IS NOT NULL AND replyCheck = \(QuoteCheck.unchecked.rawValue)
                    """,
                arguments: [
                    settlement.check.rawValue, StoredText.bytes(settlement.snippet), settlement.hasAttachment,
                    settlement.moderation.rawValue, StoredText.bytes(id),
                ]
            )
            return db.changesCount > 0
        }
    }

    /// Gives verified reply `id` its original's verdict (``MessageStore/refreshQuoteModeration(_:)``).
    @discardableResult
    public func refreshQuoteModeration(_ id: String) -> Bool {
        let waiting = MessageModeration.waiting.rawValue
        return database.write(or: false) { db in
            try db.execute(
                sql: """
                    UPDATE messages SET replyToFlagged = coalesce((\(Self.originalVerdict)), replyToFlagged)
                    WHERE id = ? AND replyCheck = \(QuoteCheck.verified.rawValue) AND replyToFlagged = \(waiting)
                        AND coalesce((\(Self.originalVerdict)), \(waiting)) != \(waiting)
                    """,
                arguments: [StoredText.bytes(id)]
            )
            return db.changesCount > 0
        }
    }

    /// The unchecked replies quoting `originalId` (``MessageStore/repliesAwaiting(_:me:limit:)``).
    public func repliesAwaiting(_ originalId: String, me: NodeId, limit: Int) -> [MessageRecord] {
        database.read(or: []) { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.columns) FROM messages
                    WHERE replyToId = ? AND replyCheck = \(QuoteCheck.unchecked.rawValue) AND senderId != ?
                    ORDER BY seq LIMIT ?
                    """,
                arguments: [StoredText.bytes(originalId), StoredText.bytes(me.string), limit]
            ).map(Self.record)
        }
    }

    /// The start's backlog (``MessageStore/unsettledQuotes(me:limit:)``).
    public func unsettledQuotes(me: NodeId, limit: Int) -> [MessageRecord] {
        database.read(or: []) { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.columns) FROM messages
                    WHERE replyToId IS NOT NULL AND replyCheck = \(QuoteCheck.unchecked.rawValue) AND senderId != ?
                        AND EXISTS (SELECT 1 FROM messages AS o WHERE o.id = messages.replyToId)
                    ORDER BY seq LIMIT ?
                    """,
                arguments: [StoredText.bytes(me.string), limit]
            ).map(Self.record)
        }
    }
}
