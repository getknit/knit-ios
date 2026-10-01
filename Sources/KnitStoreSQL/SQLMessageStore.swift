import GRDB
public import KnitStore
public import KnitWire

/// The ``MessageStore`` on SQLite: the `messages` table (`MessageDao.kt` in knit-next).
///
/// A thread reads in `sentAt` order, ties in the order rows were first stored: the table's `seq`, which a save
/// over an existing row keeps.
public final class SQLMessageStore: MessageStore {
    private static let columns = "id, senderId, recipientId, conversationId, body, sentAt, arrivedAt, delivered, pendingKey, kind"
    private static let insert = "INSERT INTO messages (\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"

    private let database: KnitDatabase

    /// The messages table in `database`.
    public init(_ database: KnitDatabase) {
        self.database = database
    }

    public func message(_ id: String) -> MessageRecord? {
        database.read(or: nil) { db in
            try Row.fetchOne(db, sql: "SELECT \(Self.columns) FROM messages WHERE id = ?", arguments: [StoredText.bytes(id)])
                .map(Self.record)
        }
    }

    public func contains(_ id: String) -> Bool {
        database.read(or: false) { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM messages WHERE id = ?)", arguments: [StoredText.bytes(id)])
                ?? false
        }
    }

    @discardableResult
    public func insertIfAbsent(_ message: MessageRecord) -> Bool {
        database.write(or: false) { db in
            try db.execute(sql: "\(Self.insert) ON CONFLICT (id) DO NOTHING", arguments: Self.arguments(message))
            return db.changesCount > 0
        }
    }

    public func save(_ message: MessageRecord) {
        // An upsert, not INSERT OR REPLACE: a replace deletes the row and takes a new seq, which would move the
        // message to the end of its ties.
        database.write(or: ()) { db in
            try db.execute(
                sql: """
                    \(Self.insert) ON CONFLICT (id) DO UPDATE SET
                        senderId = excluded.senderId, recipientId = excluded.recipientId,
                        conversationId = excluded.conversationId, body = excluded.body, sentAt = excluded.sentAt,
                        arrivedAt = excluded.arrivedAt, delivered = excluded.delivered, pendingKey = excluded.pendingKey,
                        kind = excluded.kind
                    """,
                arguments: Self.arguments(message)
            )
        }
    }

    @discardableResult
    public func markDelivered(_ id: String) -> Bool {
        database.write(or: false) { db in
            try db.execute(sql: "UPDATE messages SET delivered = 1 WHERE id = ? AND delivered = 0", arguments: [StoredText.bytes(id)])
            return db.changesCount > 0
        }
    }

    public func pendingKey(to recipient: NodeId) -> [MessageRecord] {
        database.read(or: []) { db in
            try Row.fetchAll(
                db,
                sql: "SELECT \(Self.columns) FROM messages WHERE pendingKey = 1 AND recipientId = ? ORDER BY sentAt, seq",
                arguments: [StoredText.bytes(recipient.string)]
            ).map(Self.record)
        }
    }

    public func pendingKey(in conversationId: String) -> [MessageRecord] {
        database.read(or: []) { db in
            try Row.fetchAll(
                db,
                sql: "SELECT \(Self.columns) FROM messages WHERE pendingKey = 1 AND conversationId = ? ORDER BY sentAt, seq",
                arguments: [StoredText.bytes(conversationId)]
            ).map(Self.record)
        }
    }

    public func clearPendingKey(_ id: String) {
        database.write(or: ()) { db in
            try db.execute(sql: "UPDATE messages SET pendingKey = 0 WHERE id = ?", arguments: [StoredText.bytes(id)])
        }
    }

    public func conversations(authoredBy author: NodeId) -> Set<String> {
        database.read(or: []) { db in
            Set(
                try Row.fetchAll(
                    db,
                    sql: "SELECT DISTINCT conversationId FROM messages WHERE senderId = ?",
                    arguments: [StoredText.bytes(author.string)]
                ).map { try $0.text("conversationId") }
            )
        }
    }

    public func senders(in conversationId: String) -> Set<NodeId> {
        database.read(or: []) { db in
            Set(
                try Row.fetchAll(
                    db,
                    sql: "SELECT DISTINCT senderId FROM messages WHERE conversationId = ? AND kind = 0",
                    arguments: [StoredText.bytes(conversationId)]
                ).map { try $0.nodeId("senderId") }
            )
        }
    }

    public func messages(in conversationId: String) -> [MessageRecord] {
        database.read(or: []) { db in
            try Row.fetchAll(
                db,
                sql: "SELECT \(Self.columns) FROM messages WHERE conversationId = ? ORDER BY sentAt, seq",
                arguments: [StoredText.bytes(conversationId)]
            ).map(Self.record)
        }
    }

    public func threadHeads() -> [MessageRecord] {
        // One seek per thread down the (conversationId, sentAt, seq) index, however long the threads grow. A status line
        // is never a head, so a thread of nothing else has none.
        let headColumns = Self.columns.split(separator: ", ").map { "m.\($0)" }.joined(separator: ", ")
        return database.read(or: []) { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(headColumns) FROM (SELECT DISTINCT conversationId AS thread FROM messages WHERE kind = 0) AS t
                    JOIN messages AS m ON m.seq = (
                        SELECT seq FROM messages WHERE conversationId = t.thread AND kind = 0 ORDER BY sentAt DESC, seq DESC LIMIT 1
                    )
                    ORDER BY m.sentAt DESC, m.seq DESC
                    """
            ).map(Self.record)
        }
    }

    public func deleteMessages(in conversationId: String) {
        database.write(or: ()) { db in
            try db.execute(sql: "DELETE FROM messages WHERE conversationId = ?", arguments: [StoredText.bytes(conversationId)])
        }
    }

    /// The values for ``insert``, in ``columns`` order.
    private static func arguments(_ message: MessageRecord) -> StatementArguments {
        [
            StoredText.bytes(message.id), StoredText.bytes(message.senderId.string), StoredText.bytes(message.recipientId?.string),
            StoredText.bytes(message.conversationId), StoredText.bytes(message.body), message.sentAt, message.arrivedAt,
            message.delivered, message.pendingKey, message.kind.rawValue,
        ]
    }

    /// The message in a row of ``columns``.
    private static func record(_ row: Row) throws -> MessageRecord {
        MessageRecord(
            id: try row.text("id"),
            senderId: try row.nodeId("senderId"),
            recipientId: try row.optionalNodeId("recipientId"),
            conversationId: try row.text("conversationId"),
            body: try row.text("body"),
            sentAt: try row.decode(Int64.self, forColumn: "sentAt"),
            arrivedAt: try row.decode(Int64?.self, forColumn: "arrivedAt"),
            delivered: try row.decode(Bool.self, forColumn: "delivered"),
            pendingKey: try row.decode(Bool.self, forColumn: "pendingKey"),
            kind: MessageKind(rawValue: try row.decode(Int.self, forColumn: "kind"))
        )
    }
}
