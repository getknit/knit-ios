import GRDB
public import KnitStore
public import KnitWire

/// The ``BlockStore`` on SQLite: the `blocked_nodes` and `blocked_device_tags` tables. knit-next keeps both sets in its
/// settings DataStore; here they sit beside `accepted_conversations`, under the same protection.
public final class SQLBlockStore: BlockStore {
    private let database: KnitDatabase

    /// The block list in `database`.
    public init(_ database: KnitDatabase) {
        self.database = database
    }

    public func blockedNodeIds() -> Set<NodeId> {
        database.read(or: []) { db in
            Set(try Row.fetchAll(db, sql: "SELECT nodeId FROM blocked_nodes").map { try $0.nodeId("nodeId") })
        }
    }

    public func isBlocked(deviceTag: String) -> Bool {
        // A BLOB compares by its bytes, as the tag must (ADR 2026-09.jc2x).
        database.read(or: false) { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM blocked_device_tags WHERE deviceTag = ?)",
                arguments: [StoredText.bytes(deviceTag)]
            ) ?? false
        }
    }

    public func block(_ nodeId: NodeId, deviceTag: String?) {
        database.write(or: ()) { db in
            try db.execute(
                sql: "INSERT INTO blocked_nodes (nodeId) VALUES (?) ON CONFLICT DO NOTHING",
                arguments: [StoredText.bytes(nodeId.string)]
            )
            if let deviceTag {
                try db.execute(
                    sql: "INSERT INTO blocked_device_tags (deviceTag) VALUES (?) ON CONFLICT DO NOTHING",
                    arguments: [StoredText.bytes(deviceTag)]
                )
            }
        }
    }

    public func unblock(_ nodeId: NodeId, deviceTag: String?) {
        database.write(or: ()) { db in
            try db.execute(sql: "DELETE FROM blocked_nodes WHERE nodeId = ?", arguments: [StoredText.bytes(nodeId.string)])
            if let deviceTag {
                try db.execute(sql: "DELETE FROM blocked_device_tags WHERE deviceTag = ?", arguments: [StoredText.bytes(deviceTag)])
            }
        }
    }
}
