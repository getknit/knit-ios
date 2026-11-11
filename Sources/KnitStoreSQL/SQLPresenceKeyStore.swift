import Foundation
import GRDB
public import KnitStore
public import KnitWire

/// The ``PresenceKeyStore`` on SQLite: `peer_presence_keys` (schema v22, ADR 2026-11.sv5t) and `own_presence_keys` (schema
/// v24, ADR 2026-11.prsp), with `PresenceKeyDao`'s rows (knit-next `data/presencekey/PresenceKeyDao.kt` at `cad69c77b`).
/// Every peer id is its UTF-8 bytes in a `BLOB` (``StoredText``), every root tag the signed integer Android keeps, and an
/// own key's audience its node ids sorted and comma-joined (`PresenceKeyAudience`), node ids holding no comma.
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

    public func ownKeys() -> [OwnPresenceKeyRecord] {
        database.read(or: []) { db in
            try Row.fetchAll(db, sql: "SELECT * FROM own_presence_keys ORDER BY generation DESC").map(Self.own)
        }
    }

    public func applyOwn(inserted: [OwnPresenceKeyRecord], updated: [OwnPresenceKeyRecord], keep: Set<Int64>) {
        // `applyOwn` in one write (`PresenceKeyRepository.kt:45-68`): an update moves the activation and the audience alone,
        // never the mark (`updateOwn`, `PresenceKeyDao.kt:28-35`), a new generation is inserted and never replaces one
        // (`insertOwn`'s ABORT: a conflict is an error, which fails the unit), and the generations not kept go.
        database.write(or: ()) { db in
            for row in updated {
                try db.execute(
                    sql: "UPDATE own_presence_keys SET activatedAt = ?, audience = ? WHERE generation = ?",
                    arguments: [row.activatedAt, Self.audience(row.audience), row.generation]
                )
            }
            for row in inserted {
                try db.execute(
                    sql: "INSERT INTO own_presence_keys (generation, key, mintedAt, activatedAt, audience) VALUES (?, ?, ?, ?, ?)",
                    arguments: [row.generation, Data(row.keyBytes), row.mintedAt, row.activatedAt, Self.audience(row.audience)]
                )
            }
            let kept = keep.sorted()
            let placeholders = kept.map { _ in "?" }.joined(separator: ", ")
            try db.execute(
                sql: "DELETE FROM own_presence_keys WHERE generation NOT IN (\(placeholders))", arguments: StatementArguments(kept))
        }
    }

    public func mark(of generation: Int64) -> PresenceMark? {
        database.read(or: nil) { db in
            try Row.fetchOne(db, sql: "SELECT markSlot, markRestart FROM own_presence_keys WHERE generation = ?", arguments: [generation])
                .flatMap(Self.mark)
        }
    }

    /// Writes the advertiser's mark durably against power loss, and only under the current key (`markStore`'s `write`,
    /// `PresenceKeyRepository.kt:184-251`; ADR 2026-11.prsp, "Where each piece is stored"):
    /// 1. Never inside a store unit: SQLite refuses to change the safety level inside a transaction, and that refusal
    ///    would fail the caller's unit. One there answers ``PresenceMarkWrite/insideUnit`` before anything runs.
    /// 2. One closure on the writer's connection, never ``KnitDatabase/write(or:)``: `PRAGMA synchronous=FULL` first,
    ///    outside any transaction.
    /// 3. Then a transaction that reads the pragma back on the connection that will commit, and refuses unless it is 2
    ///    (FULL), and runs the conditional update, which lands only while `generation` is the newest activated key
    ///    (`setCurrentMark`, `PresenceKeyDao.kt:45-60`): no row changed is a key a rotation demoted, refused, so nothing
    ///    airs under a key a leaver holds. In WAL mode a FULL commit syncs the log, and every earlier commit with it.
    /// 4. Always, `PRAGMA synchronous=NORMAL` again, what the pool runs otherwise. A failure there is reported and swallowed:
    ///    the connection stays at FULL, slower and never unsafe.
    ///
    /// Cost: one fsync per mark, a few hundred a day. No answer names the generation: a logged refusal would date a block.
    public func writeMark(_ mark: PresenceMark, of generation: Int64) -> PresenceMarkWrite {
        guard !database.unitRunsOnThisThread else {
            return .insideUnit
        }
        var outcome = PresenceMarkWrite.failed
        do {
            try database.writer.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA synchronous=FULL")
                defer {
                    do {
                        try db.execute(sql: "PRAGMA synchronous=NORMAL")
                    } catch {
                        database.report(error)
                    }
                }
                try db.inTransaction(.immediate) {
                    guard try Int64.fetchOne(db, sql: "PRAGMA synchronous") == Self.synchronousFull else {
                        outcome = .notFull
                        return .rollback
                    }
                    try db.execute(
                        sql: """
                            UPDATE own_presence_keys SET markSlot = ?, markRestart = ? WHERE generation = ? AND activatedAt IS NOT NULL
                            AND generation = (SELECT MAX(generation) FROM own_presence_keys WHERE activatedAt IS NOT NULL)
                            """,
                        arguments: [mark.slot, mark.restart, generation]
                    )
                    guard db.changesCount == 1 else {
                        outcome = .refused
                        return .rollback
                    }
                    outcome = .durable
                    return .commit
                }
            }
        } catch {
            database.report(error)
            return .failed
        }
        return outcome
    }

    /// `PRAGMA synchronous`'s FULL; NORMAL is 1 (`SYNCHRONOUS_FULL`, `PresenceKeyRepository.kt:270`).
    private static let synchronousFull: Int64 = 2

    /// An audience as its row keeps it: the node ids sorted and comma-joined (`PresenceKeyAudience.encode`).
    private static func audience(_ ids: Set<NodeId>) -> Data {
        StoredText.bytes(ids.map(\.string).sorted().joined(separator: ","))
    }

    /// One own key's row, or a thrown error for a key that is not 32 bytes or an audience naming anything but node ids,
    /// which only a damaged file holds.
    private static func own(_ row: Row) throws -> OwnPresenceKeyRecord {
        let text = try row.text("audience")
        let ids = text.isEmpty ? [] : text.split(separator: ",", omittingEmptySubsequences: false).map { NodeId(String($0)) }
        guard ids.allSatisfy({ $0 != nil }) else {
            throw StoredValueError(column: "audience")
        }
        guard
            let record = OwnPresenceKeyRecord(
                generation: try row.decode(Int64.self, forColumn: "generation"),
                keyBytes: try row.bytes("key"),
                mintedAt: try row.decode(Int64.self, forColumn: "mintedAt"),
                activatedAt: try row.decode(Int64?.self, forColumn: "activatedAt"),
                audience: Set(ids.compactMap(\.self)),
                mark: try mark(row)
            )
        else {
            throw StoredValueError(column: "key")
        }
        return record
    }

    /// The mark a row holds, or `nil` before it first aired; a restart left empty reads 0, as Android reads it.
    private static func mark(_ row: Row) throws -> PresenceMark? {
        guard let slot = try row.decode(Int64?.self, forColumn: "markSlot") else {
            return nil
        }
        return PresenceMark(slot: slot, restart: try row.decode(Int?.self, forColumn: "markRestart") ?? 0)
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
