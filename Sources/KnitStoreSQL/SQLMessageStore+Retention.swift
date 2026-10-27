import GRDB
public import KnitStore

// Retention, apart from the class only to keep its body inside the lint's length.
extension SQLMessageStore {
    /// How many ids one statement binds: far under SQLite's limit, and a pass trims at most a few thousand.
    static let retentionBatch = 500

    /// The rows of threads `conversationIds` as retention weighs them, read down the thread index a batch of threads at a
    /// time (``MessageStore/retentionRows(in:)``).
    public func retentionRows(in conversationIds: Set<String>) -> [RetentionRow] {
        let threads = conversationIds.map(StoredText.bytes)
        return database.read(or: []) { db in
            try stride(from: 0, to: threads.count, by: Self.retentionBatch).flatMap { start in
                let batch = Array(threads[start..<min(start + Self.retentionBatch, threads.count)])
                let sql = "SELECT id, conversationId, senderId, sentAt, kind FROM messages WHERE conversationId IN"
                return try Row.fetchAll(db, sql: "\(sql) (\(Self.marks(batch.count)))", arguments: StatementArguments(batch)).map { row in
                    RetentionRow(
                        id: try row.text("id"),
                        conversationId: try row.text("conversationId"),
                        senderId: try row.nodeId("senderId"),
                        sentAt: try row.decode(Int64.self, forColumn: "sentAt"),
                        kind: MessageKind(rawValue: try row.decode(Int.self, forColumn: "kind"))
                    )
                }
            }
        }
    }

    /// Removes rows `ids` a batch at a time and tombstones those a carrier could still re-serve, with no photo, all in one
    /// transaction (``MessageStore/trimMessages(_:at:)``).
    @discardableResult
    public func trimMessages(_ ids: [String], at now: Int64) -> [MessageRecord] {
        let keys = ids.map(StoredText.bytes)
        return database.write(or: []) { db in
            try stride(from: 0, to: keys.count, by: Self.retentionBatch).flatMap { start in
                let batch = Array(keys[start..<min(start + Self.retentionBatch, keys.count)])
                let marks = Self.marks(batch.count)
                let removed = try Row.fetchAll(
                    db, sql: "SELECT \(Self.columns) FROM messages WHERE id IN (\(marks))", arguments: StatementArguments(batch)
                ).map(Self.record)
                try db.execute(sql: "DELETE FROM messages WHERE id IN (\(marks))", arguments: StatementArguments(batch))
                for record in removed {
                    let expiry = DeletedMessages.trimmedExpiry(
                        sentAt: record.sentAt, kind: record.kind, conversationId: record.conversationId, at: now)
                    guard let expiry else {
                        continue
                    }
                    // A delete's tombstone keeps its photo and the later expiry; this one adds no photo.
                    try db.execute(
                        sql: """
                            INSERT INTO deleted_messages (id, expiresAt, attachmentHash) VALUES (?, ?, NULL)
                            ON CONFLICT (id) DO UPDATE SET expiresAt = max(expiresAt, excluded.expiresAt)
                            """,
                        arguments: [StoredText.bytes(record.id), expiry]
                    )
                }
                return removed
            }
        }
    }

    /// `count` placeholders for an `IN` list.
    private static func marks(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
