import GRDB
public import KnitStore
public import KnitWire

/// The ``PeerStore`` on SQLite: the `peers` table (`PeerDao.kt` in knit-next).
public final class SQLPeerStore: PeerStore {
    private static let columns =
        "nodeId, name, status, publicKey, deviceTag, protocolVersion, capabilities, updatedAt, verified, openToChat"

    private let database: KnitDatabase

    /// The peers table in `database`.
    public init(_ database: KnitDatabase) {
        self.database = database
    }

    public func peer(_ nodeId: NodeId) -> PeerRecord? {
        database.read(or: nil) { db in
            try Row.fetchOne(
                db,
                sql: "SELECT \(Self.columns) FROM peers WHERE nodeId = ?",
                arguments: [StoredText.bytes(nodeId.string)]
            ).map(Self.record)
        }
    }

    public func upsert(_ peer: PeerRecord) {
        database.write(or: ()) { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO peers (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    StoredText.bytes(peer.nodeId.string), StoredText.bytes(peer.name), StoredText.bytes(peer.status),
                    StoredText.bytes(peer.publicKey), StoredText.bytes(peer.deviceTag), peer.protocolVersion, peer.capabilities,
                    peer.updatedAt, peer.verified, peer.openToChat,
                ]
            )
        }
    }

    public func verifiedNodeIds() -> Set<NodeId> {
        database.read(or: []) { db in
            Set(try Row.fetchAll(db, sql: "SELECT nodeId FROM peers WHERE verified = 1").map { try $0.nodeId("nodeId") })
        }
    }

    public func allPeers() -> [PeerRecord] {
        // BLOB order is byte order, which is how node ids compare.
        database.read(or: []) { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.columns) FROM peers ORDER BY nodeId").map(Self.record)
        }
    }

    /// The peer in a row of ``columns``.
    private static func record(_ row: Row) throws -> PeerRecord {
        PeerRecord(
            nodeId: try row.nodeId("nodeId"),
            name: try row.text("name"),
            status: try row.text("status"),
            publicKey: try row.text("publicKey"),
            deviceTag: try row.optionalText("deviceTag"),
            protocolVersion: try row.decode(Int?.self, forColumn: "protocolVersion"),
            capabilities: try row.decode(Int64?.self, forColumn: "capabilities"),
            updatedAt: try row.decode(Int64.self, forColumn: "updatedAt"),
            verified: try row.decode(Bool.self, forColumn: "verified"),
            openToChat: try row.decode(Bool.self, forColumn: "openToChat")
        )
    }
}
