// v20 lives here so the schema's enum stays inside the lint's length; like every migration it is frozen once committed.

extension Schema {
    /// Schema v20: a received quote checked against the original it names (knit-next ADR 2026-10.gpa3). `replyCheck` holds
    /// ``KnitStore/QuoteCheck``'s code, Android's `REPLY_*` values, and `replyToFlagged` the content filter's verdict on the
    /// quote's words apart from the body's (``KnitStore/MessageModeration``'s codes, as `moderation` holds them). Both are
    /// local only, under Android's names (`MessageEntity.replyCheck`, `replyToFlagged`, DB v22). Every row already stored
    /// starts unchecked and unflagged, and the start's backlog settles those whose original is held.
    ///
    /// `messages_replyToId` serves the replies an original settles as it lands, and the verdict an original's screen passes
    /// to its verified replies (`MessageDao`'s `(replyToId, replyCheck)` index); `messages_quoteWaiting` serves the quotes a
    /// launch still has to screen, as `messages_waiting` serves the bodies.
    static let v20 = [
        "ALTER TABLE messages ADD COLUMN replyCheck INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE messages ADD COLUMN replyToFlagged INTEGER NOT NULL DEFAULT 0",
        "CREATE INDEX messages_replyToId ON messages (replyToId, replyCheck) WHERE replyToId IS NOT NULL",
        "CREATE INDEX messages_quoteWaiting ON messages (seq) WHERE replyToFlagged = 2 AND replyCheck = 0",
    ]
}
