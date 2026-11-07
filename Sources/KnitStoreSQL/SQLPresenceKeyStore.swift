import Foundation
import GRDB
public import KnitStore
public import KnitWire

/// The ``PresenceKeyStore`` on SQLite: `peer_presence_keys` (schema v22, ADR 2026-11.sv5t), with `PresenceKeyDao`'s peer
/// rows (knit-next `data/presencekey/PresenceKeyDao.kt` at `cad69c77b`). Every peer id is its UTF-8 bytes in a `BLOB`
/// (``StoredText``), and every root tag the signed integer Android keeps.
///
/// Its reads and writes go through ``KnitDatabase``'s `read(or:)` and `write(or:)`, as ``SQLRatchetStore``'s do, so inside
/// a store unit they join it and any error, a read's as much as a write's, fails the unit; outside one a write is a
/// transaction of its own. A row whose key is not 32 bytes, which only a damaged file holds, fails the read rather than
/// reading as no key. What it deletes is zeroed in the next write of its page (`secure_delete`, ``KnitDatabase``).
public final class SQLPresenceKeyStore: PresenceKeyStore {
    private let database: KnitDatabase

    /// The presence keys in `database`.
    public init(_ database: KnitDatabase) {
        self.database = database
    }

    public func keys(of peer: NodeId) -> [StoredPresenceKey] {
        database.read(or: []) { db in
            try Self.keys(of: StoredText.bytes(peer.string), in: db)
        }
    }

    public func replaceKeys(of peer: NodeId, with rows: [HeldPresenceKey], now: Int64) {
        // `applyHeld`'s rows in one write (`PresenceKeyRepository.kt:77-96`): a row whose bytes and root are unchanged keeps
        // its first arrival, every other generation is written afresh, and the generations not kept go.
        database.write(or: ()) { db in
            let peerId = StoredText.bytes(peer.string)
            let before = Dictionary(try Self.keys(of: peerId, in: db).map { ($0.held.generation, $0) }) { first, _ in first }
            try db.execute(sql: "DELETE FROM peer_presence_keys WHERE nodeId = ?", arguments: [peerId])
            for row in rows {
                let kept = before[row.generation].flatMap { $0.held == row ? $0.receivedAt : nil }
                try db.execute(
                    sql: "INSERT OR REPLACE INTO peer_presence_keys (nodeId, generation, key, receivedAt, rootTag) VALUES (?, ?, ?, ?, ?)",
                    arguments: [peerId, row.generation, Data(row.keyBytes), kept ?? now, row.rootTag]
                )
            }
        }
    }

    public func peersWithKeys() -> [NodeId] {
        // A node id is its UTF-8 bytes in a BLOB, which SQLite orders as memcmp does: ASCII order for a node id.
        database.read(or: []) { db in
            try Row.fetchAll(db, sql: "SELECT DISTINCT nodeId FROM peer_presence_keys ORDER BY nodeId").map { try $0.nodeId("nodeId") }
        }
    }

    public func deleteKeys(of peers: Set<NodeId>) {
        guard !peers.isEmpty else {
            return
        }
        database.write(or: ()) { db in
            for peer in peers.sorted() {
                try db.execute(sql: "DELETE FROM peer_presence_keys WHERE nodeId = ?", arguments: [StoredText.bytes(peer.string)])
            }
        }
    }

    private static func keys(of peerId: Data, in db: Database) throws -> [StoredPresenceKey] {
        try Row.fetchAll(
            db,
            sql: "SELECT generation, key, receivedAt, rootTag FROM peer_presence_keys WHERE nodeId = ? ORDER BY generation DESC",
            arguments: [peerId]
        ).map { row in
            guard
                let stored = StoredPresenceKey(
                    generation: try row.decode(Int64.self, forColumn: "generation"),
                    keyBytes: try row.bytes("key"),
                    rootTag: try row.decode(Int64.self, forColumn: "rootTag"),
                    receivedAt: try row.decode(Int64.self, forColumn: "receivedAt")
                )
            else {
                throw StoredValueError(column: "key")
            }
            return stored
        }
    }
}
