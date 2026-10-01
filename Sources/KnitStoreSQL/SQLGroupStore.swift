import GRDB
public import KnitStore

/// The ``GroupStore`` on SQLite: the `groups` table, and `group_members` for each roster in its order (schema v3,
/// ADR 2026-09.n393).
public final class SQLGroupStore: GroupStore {
    private static let columns = "groupId, name, createdBy, createdAt, nameUpdatedAt, hasLeft, photoHash, photoUpdatedAt"

    private let database: KnitDatabase

    /// The groups in `database`.
    public init(_ database: KnitDatabase) {
        self.database = database
    }

    public func group(_ id: String) -> GroupRecord? {
        database.read(or: nil) { db in
            try Row.fetchOne(db, sql: "SELECT \(Self.columns) FROM groups WHERE groupId = ?", arguments: [StoredText.bytes(id)])
                .map { try Self.record($0, in: db) }
        }
    }

    public func groups() -> [GroupRecord] {
        database.read(or: []) { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.columns) FROM groups ORDER BY groupId").map { try Self.record($0, in: db) }
        }
    }

    public func save(_ group: GroupRecord) {
        // The row and its whole roster in one transaction, so a reader never sees one without the other.
        database.write(or: ()) { db in
            let id = StoredText.bytes(group.id)
            try db.execute(
                sql: """
                    INSERT INTO groups (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (groupId) DO UPDATE SET
                        name = excluded.name, createdBy = excluded.createdBy, createdAt = excluded.createdAt,
                        nameUpdatedAt = excluded.nameUpdatedAt, hasLeft = excluded.hasLeft, photoHash = excluded.photoHash,
                        photoUpdatedAt = excluded.photoUpdatedAt
                    """,
                arguments: [
                    id, StoredText.bytes(group.name), StoredText.bytes(group.createdBy), group.createdAt, group.nameUpdatedAt,
                    group.hasLeft, StoredText.bytes(group.photoHash), group.photoUpdatedAt,
                ]
            )
            try db.execute(sql: "DELETE FROM group_members WHERE groupId = ?", arguments: [id])
            for (position, member) in group.roster.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO group_members (groupId, nodeId, position, departed, leftAt, rejoinedAt)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [id, StoredText.bytes(member.nodeId), position, member.departed, member.leftAt, member.rejoinedAt]
                )
            }
        }
    }

    /// The group in a row of ``columns``, with its roster read in order.
    private static func record(_ row: Row, in db: Database) throws -> GroupRecord {
        let id = try row.text("groupId")
        let roster = try Row.fetchAll(
            db,
            sql: "SELECT nodeId, departed, leftAt, rejoinedAt FROM group_members WHERE groupId = ? ORDER BY position",
            arguments: [StoredText.bytes(id)]
        ).map { member in
            GroupMember(
                nodeId: try member.text("nodeId"),
                departed: try member.decode(Bool.self, forColumn: "departed"),
                leftAt: try member.decode(Int64?.self, forColumn: "leftAt"),
                rejoinedAt: try member.decode(Int64?.self, forColumn: "rejoinedAt")
            )
        }
        return GroupRecord(
            id: id,
            name: try row.text("name"),
            createdBy: try row.text("createdBy"),
            createdAt: try row.decode(Int64.self, forColumn: "createdAt"),
            nameUpdatedAt: try row.decode(Int64.self, forColumn: "nameUpdatedAt"),
            hasLeft: try row.decode(Bool.self, forColumn: "hasLeft"),
            photoHash: try row.optionalText("photoHash"),
            photoUpdatedAt: try row.decode(Int64?.self, forColumn: "photoUpdatedAt"),
            roster: roster
        )
    }
}
