import GRDB
public import KnitStore

/// The ``ConversationStore`` on SQLite: the `accepted_conversations` table. knit-next keeps the set in its
/// settings DataStore; here it sits beside the messages it gates, under the same protection.
public final class SQLConversationStore: ConversationStore {
    private let database: KnitDatabase

    /// The accepted conversations in `database`.
    public init(_ database: KnitDatabase) {
        self.database = database
    }

    public func acceptedConversations() -> Set<String> {
        database.read(or: []) { db in
            Set(try Row.fetchAll(db, sql: "SELECT conversationId FROM accepted_conversations").map { try $0.text("conversationId") })
        }
    }

    public func accept(_ conversationId: String) {
        database.write(or: ()) { db in
            try db.execute(
                sql: "INSERT INTO accepted_conversations (conversationId) VALUES (?) ON CONFLICT DO NOTHING",
                arguments: [StoredText.bytes(conversationId)]
            )
        }
    }
}
