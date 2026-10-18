import Foundation
import GRDB
public import KnitStore
public import KnitWire

/// The ``RatchetStore`` on SQLite: `ratchet_sessions`, `ratchet_local_epochs`, `ratchet_recv_epochs` and
/// `ratchet_skipped_keys` (schema v17, ADR 2026-10.5sk9), with `RatchetDao`'s row rules (knit-next
/// `data/ratchet/RatchetDao.kt:18-118`): the session, a receive chain and a local epoch are `INSERT OR REPLACE`, a skipped
/// key `INSERT OR IGNORE`, and a spent key is deleted by its full key, root tag included. Every peer id is its UTF-8 bytes
/// in a `BLOB` (``StoredText``), and every root tag the signed integer Android keeps.
///
/// Each write is one transaction of its own outside a store unit, and one savepoint inside it, so an open's rows land
/// together or not at all either way. The sweep applies ``RatchetRetention`` in Swift over what it reads, as
/// ``SQLCustodyStore`` applies ``CustodyRules``, so this store and ``MemoryRatchetStore`` retire the same rows. What it
/// deletes is zeroed in the next write of its page (`secure_delete`, ``KnitDatabase``), which goes to the write-ahead
/// log. Once the sweep commits, a truncating checkpoint copies those pages over the file and empties the log, unless a
/// reader holds a snapshot of the log then (``truncateLog(_:reporting:)``).
public final class SQLRatchetStore: RatchetStore {
    private static let sessionColumns = """
        peerId, confirmed, weAreInitiator, root, prevRoot, prevRootWeAreInitiator, prevRootExpiresAt, establishedAt, \
        initEphPub, initPkid, peerInitEphPub, peerBasePub, peerBaseEpoch, sendEpoch, sendEpochPub, sendChainKey, sendCount, \
        sendEpochStartedAt, sendEpochBaseEpoch, highestPeAcked, lastResetSentAt
        """
    private static let chainColumns = "epoch, rootTag, chainKey, next, lastUsedAt"
    private static let skippedKeyColumns = "epoch, rootTag, idx, msgKey, createdAt"

    private let database: KnitDatabase

    /// The ratchet's rows in `database`.
    public init(_ database: KnitDatabase) {
        self.database = database
    }

    public func session(_ peer: NodeId) -> RatchetSessionRecord? {
        database.read(or: nil) { db in
            try Row.fetchOne(
                db,
                sql: "SELECT \(Self.sessionColumns) FROM ratchet_sessions WHERE peerId = ?",
                arguments: [StoredText.bytes(peer.string)]
            ).map(Self.session)
        }
    }

    public func sessionPeerIds() -> [NodeId] {
        // A peer id is its UTF-8 bytes in a BLOB, which SQLite orders as memcmp does: ASCII order for a node id.
        database.read(or: []) { db in
            try Row.fetchAll(db, sql: "SELECT peerId FROM ratchet_sessions ORDER BY peerId").map { try $0.nodeId("peerId") }
        }
    }

    public func upsertSession(_ session: RatchetSessionRecord) {
        database.write(or: ()) { db in
            try Self.upsert(session, in: db)
        }
    }

    public func localEpochPrivateKey(_ peer: NodeId, epoch: Int) -> [UInt8]? {
        database.read(or: nil) { db in
            try Data.fetchOne(
                db,
                sql: "SELECT priv FROM ratchet_local_epochs WHERE peerId = ? AND epoch = ?",
                arguments: [StoredText.bytes(peer.string), epoch]
            ).map { [UInt8]($0) }
        }
    }

    public func lowestLocalEpoch(_ peer: NodeId) -> Int? {
        database.read(or: nil) { db in
            try Int.fetchOne(
                db, sql: "SELECT MIN(epoch) FROM ratchet_local_epochs WHERE peerId = ?", arguments: [StoredText.bytes(peer.string)])
        }
    }

    public func recvEpochs(_ peer: NodeId, epoch: Int) -> [RatchetRecvEpochRecord] {
        database.read(or: []) { db in
            try Row.fetchAll(
                db,
                sql: "SELECT \(Self.chainColumns) FROM ratchet_recv_epochs WHERE peerId = ? AND epoch = ? ORDER BY rootTag",
                arguments: [StoredText.bytes(peer.string), epoch]
            ).map(Self.chain)
        }
    }

    public func skippedKeys(_ peer: NodeId, epoch: Int, index: Int) -> [RatchetSkippedKeyRecord] {
        database.read(or: []) { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.skippedKeyColumns) FROM ratchet_skipped_keys WHERE peerId = ? AND epoch = ? AND idx = ?
                    ORDER BY rootTag
                    """,
                arguments: [StoredText.bytes(peer.string), epoch, index]
            ).map(Self.skippedKey)
        }
    }

    public func applyOpen(_ delta: RatchetOpenDelta, from peer: NodeId, se: Int, n: Int) {
        // The whole delta in one write, in `RatchetRepository.applyOpen`'s order (`RatchetRepository.kt:54-92`).
        database.write(or: ()) { db in
            let peerId = StoredText.bytes(peer.string)
            if delta.purgePeerRecvState {
                try Self.purgeReceiveState(peerId, in: db)
            }
            try Self.upsert(delta.session, in: db)
            if let chain = delta.recvEpoch {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO ratchet_recv_epochs (peerId, \(Self.chainColumns)) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [peerId, chain.epoch, chain.rootTag, Data(chain.chainKey), chain.next, chain.lastUsedAt]
                )
            }
            for key in delta.skippedInserts {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO ratchet_skipped_keys (peerId, \(Self.skippedKeyColumns)) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [peerId, key.epoch, key.rootTag, key.index, Data(key.messageKey), key.createdAt]
                )
            }
            if let tag = delta.consumedSkippedTag {
                // One root's key only: another tag's key at the same index belongs to another era's frame (`RatchetDao.kt:95-102`).
                try db.execute(
                    sql: "DELETE FROM ratchet_skipped_keys WHERE peerId = ? AND epoch = ? AND idx = ? AND rootTag = ?",
                    arguments: [peerId, se, n, tag]
                )
            }
        }
    }

    public func commitSend(_ session: RatchetSessionRecord, newLocalEpoch: RatchetLocalEpochRecord?) {
        database.write(or: ()) { db in
            try Self.upsert(session, in: db)
            if let epoch = newLocalEpoch {
                // REPLACE: a reset restarts our numbering, and the live era's key must win the number (`RatchetDao.kt:38-44`).
                try db.execute(
                    sql: "INSERT OR REPLACE INTO ratchet_local_epochs (peerId, epoch, priv, pub, createdAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [
                        StoredText.bytes(session.peerId.string), epoch.epoch, Data(epoch.privateKey), Data(epoch.publicKey),
                        epoch.createdAt,
                    ]
                )
            }
        }
    }

    public func purgeReceiveState(_ peer: NodeId) {
        database.write(or: ()) { db in
            try Self.purgeReceiveState(StoredText.bytes(peer.string), in: db)
        }
    }

    public func deletePeer(_ peer: NodeId) {
        database.write(or: ()) { db in
            let peerId = StoredText.bytes(peer.string)
            try db.execute(sql: "DELETE FROM ratchet_sessions WHERE peerId = ?", arguments: [peerId])
            try db.execute(sql: "DELETE FROM ratchet_local_epochs WHERE peerId = ?", arguments: [peerId])
            try Self.purgeReceiveState(peerId, in: db)
        }
    }

    public func records(of peer: NodeId) -> RatchetPeerRecords {
        let empty = RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: [])
        return database.read(or: empty) { db in
            let peerId = StoredText.bytes(peer.string)
            let session = try Row.fetchOne(
                db,
                sql: "SELECT \(Self.sessionColumns) FROM ratchet_sessions WHERE peerId = ?",
                arguments: [peerId]
            )
            let epochs = try Row.fetchAll(
                db,
                sql: "SELECT epoch, priv, pub, createdAt FROM ratchet_local_epochs WHERE peerId = ? ORDER BY createdAt DESC, epoch DESC",
                arguments: [peerId]
            )
            let chains = try Row.fetchAll(
                db,
                sql: "SELECT \(Self.chainColumns) FROM ratchet_recv_epochs WHERE peerId = ? ORDER BY epoch, rootTag",
                arguments: [peerId]
            )
            let keys = try Row.fetchAll(
                db,
                sql: "SELECT \(Self.skippedKeyColumns) FROM ratchet_skipped_keys WHERE peerId = ? ORDER BY epoch, rootTag, idx",
                arguments: [peerId]
            )
            return RatchetPeerRecords(
                session: try session.map(Self.session),
                localEpochs: try epochs.map(Self.localEpoch),
                recvEpochs: try chains.map(Self.chain),
                skippedKeys: try keys.map(Self.skippedKey)
            )
        }
    }

    public func sweep(now: Int64) {
        // `RatchetRepository.sweep`'s order (`RatchetRepository.kt:121-127`), in one write.
        database.write(or: ()) { [database] db in
            try db.execute(
                sql: "DELETE FROM ratchet_skipped_keys WHERE createdAt < ?",
                arguments: [RatchetRetention.skippedKeyCutoff(now: now)]
            )
            let held = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ratchet_skipped_keys") ?? 0
            if RatchetRetention.skippedKeyExcess(count: held) > 0 {
                // Over the cap: read every key's stamp and evict as the memory store does, tiebreak included.
                let stamps = try Row.fetchAll(db, sql: "SELECT peerId, epoch, idx, rootTag, createdAt FROM ratchet_skipped_keys").map(
                    Self.stamp)
                for evicted in RatchetRetention.evictedSkippedKeys(stamps) {
                    try db.execute(
                        sql: "DELETE FROM ratchet_skipped_keys WHERE peerId = ? AND epoch = ? AND idx = ? AND rootTag = ?",
                        arguments: [StoredText.bytes(evicted.peer.string), evicted.epoch, evicted.index, evicted.rootTag]
                    )
                }
            }
            try db.execute(
                sql: "DELETE FROM ratchet_recv_epochs WHERE lastUsedAt < ?",
                arguments: [RatchetRetention.receiveChainCutoff(now: now)]
            )
            try Self.retireLocalEpochs(now: now, in: db)
            // The zeros are in the pages this write puts in the log. The file keeps the old pages, and the log the
            // frames that wrote the keys, until the truncating checkpoint once the outermost transaction this write
            // joined commits, never on a rollback.
            db.afterNextTransaction { db in
                Self.truncateLog(db, reporting: database)
            }
        }
    }
}

// The statements and row readers, apart from the class only to keep its body inside the lint's length.
extension SQLRatchetStore {
    /// Our epochs for every peer we hold a session with, retired by ``RatchetRetention`` (`sweepLocalEpochs`,
    /// `RatchetRepository.kt:141-157`).
    private static func retireLocalEpochs(now: Int64, in db: Database) throws {
        for session in try Row.fetchAll(db, sql: "SELECT peerId, highestPeAcked FROM ratchet_sessions") {
            let peerId = try session.decode(Data.self, forColumn: "peerId")
            let held = try Row.fetchAll(
                db,
                sql: "SELECT epoch, createdAt FROM ratchet_local_epochs WHERE peerId = ?",
                arguments: [peerId]
            ).map { row in
                (epoch: try row.decode(Int.self, forColumn: "epoch"), createdAt: try row.decode(Int64.self, forColumn: "createdAt"))
            }
            let acked = try session.decode(Int.self, forColumn: "highestPeAcked")
            for epoch in RatchetRetention.retiredLocalEpochs(held, highestPeAcked: acked, now: now) {
                try db.execute(sql: "DELETE FROM ratchet_local_epochs WHERE peerId = ? AND epoch = ?", arguments: [peerId, epoch])
            }
        }
    }

    /// Truncates the write-ahead log as the sweep's outermost transaction commits: `PRAGMA wal_checkpoint(TRUNCATE)`
    /// copies every frame into the file, where the sweep's deletions are zeros, then empties the log, which still held
    /// each deleted key's own insert and every chain key a seal or an open has replaced since the last truncation.
    ///
    /// GRDB 7.11.1 runs it on the writer's queue once the COMMIT has run, so outside any transaction, and drops it on a
    /// rollback (`afterNextTransaction`, TransactionObserver.swift:115-150 and 1114-1144). After a rollback SQLite made by
    /// itself, which GRDB does not see, it runs at the next commit instead, and so it does after a nested unit that swept
    /// and was abandoned inside an outer unit that commits: either costs only the checkpoint. A reader
    /// holding a snapshot of the log makes the checkpoint answer `SQLITE_BUSY` before it truncates: that is expected, and
    /// the next sweep truncates. Any other error is reported and fails nothing, as a blob's file error does.
    static func truncateLog(_ db: Database, reporting database: KnitDatabase) {
        do {
            try db.checkpoint(.truncate)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY {
            // A reader is still on the log, so it stays until the next sweep.
        } catch {
            database.report(error)
        }
    }

    private static func purgeReceiveState(_ peerId: Data, in db: Database) throws {
        try db.execute(sql: "DELETE FROM ratchet_recv_epochs WHERE peerId = ?", arguments: [peerId])
        try db.execute(sql: "DELETE FROM ratchet_skipped_keys WHERE peerId = ?", arguments: [peerId])
    }

    private static func upsert(_ session: RatchetSessionRecord, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO ratchet_sessions (\(sessionColumns))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                StoredText.bytes(session.peerId.string), session.confirmed, session.weAreInitiator, Data(session.root),
                session.prevRoot.map { Data($0) }, session.prevRootWeAreInitiator, session.prevRootExpiresAt, session.establishedAt,
                session.initEphPub.map { Data($0) }, session.initPkid, session.peerInitEphPub.map { Data($0) },
                session.peerBasePub.map { Data($0) }, session.peerBaseEpoch, session.sendEpoch, session.sendEpochPub.map { Data($0) },
                session.sendChainKey.map { Data($0) }, session.sendCount, session.sendEpochStartedAt, session.sendEpochBaseEpoch,
                session.highestPeAcked, session.lastResetSentAt,
            ]
        )
    }

    private static func session(_ row: Row) throws -> RatchetSessionRecord {
        RatchetSessionRecord(
            peerId: try row.nodeId("peerId"),
            confirmed: try row.decode(Bool.self, forColumn: "confirmed"),
            weAreInitiator: try row.decode(Bool.self, forColumn: "weAreInitiator"),
            root: try row.bytes("root"),
            prevRoot: try row.optionalBytes("prevRoot"),
            prevRootWeAreInitiator: try row.decode(Bool.self, forColumn: "prevRootWeAreInitiator"),
            prevRootExpiresAt: try row.decode(Int64.self, forColumn: "prevRootExpiresAt"),
            establishedAt: try row.decode(Int64.self, forColumn: "establishedAt"),
            initEphPub: try row.optionalBytes("initEphPub"),
            initPkid: try row.decode(Int.self, forColumn: "initPkid"),
            peerInitEphPub: try row.optionalBytes("peerInitEphPub"),
            peerBasePub: try row.optionalBytes("peerBasePub"),
            peerBaseEpoch: try row.decode(Int.self, forColumn: "peerBaseEpoch"),
            sendEpoch: try row.decode(Int.self, forColumn: "sendEpoch"),
            sendEpochPub: try row.optionalBytes("sendEpochPub"),
            sendChainKey: try row.optionalBytes("sendChainKey"),
            sendCount: try row.decode(Int.self, forColumn: "sendCount"),
            sendEpochStartedAt: try row.decode(Int64.self, forColumn: "sendEpochStartedAt"),
            sendEpochBaseEpoch: try row.decode(Int.self, forColumn: "sendEpochBaseEpoch"),
            highestPeAcked: try row.decode(Int.self, forColumn: "highestPeAcked"),
            lastResetSentAt: try row.decode(Int64.self, forColumn: "lastResetSentAt")
        )
    }

    private static func localEpoch(_ row: Row) throws -> RatchetLocalEpochRecord {
        RatchetLocalEpochRecord(
            epoch: try row.decode(Int.self, forColumn: "epoch"),
            privateKey: try row.bytes("priv"),
            publicKey: try row.bytes("pub"),
            createdAt: try row.decode(Int64.self, forColumn: "createdAt")
        )
    }

    private static func chain(_ row: Row) throws -> RatchetRecvEpochRecord {
        RatchetRecvEpochRecord(
            epoch: try row.decode(Int.self, forColumn: "epoch"),
            rootTag: try row.decode(Int64.self, forColumn: "rootTag"),
            chainKey: try row.bytes("chainKey"),
            next: try row.decode(Int.self, forColumn: "next"),
            lastUsedAt: try row.decode(Int64.self, forColumn: "lastUsedAt")
        )
    }

    private static func skippedKey(_ row: Row) throws -> RatchetSkippedKeyRecord {
        RatchetSkippedKeyRecord(
            epoch: try row.decode(Int.self, forColumn: "epoch"),
            rootTag: try row.decode(Int64.self, forColumn: "rootTag"),
            index: try row.decode(Int.self, forColumn: "idx"),
            messageKey: try row.bytes("msgKey"),
            createdAt: try row.decode(Int64.self, forColumn: "createdAt")
        )
    }

    private static func stamp(_ row: Row) throws -> RatchetSkippedKeyStamp {
        RatchetSkippedKeyStamp(
            peer: try row.nodeId("peerId"),
            epoch: try row.decode(Int.self, forColumn: "epoch"),
            index: try row.decode(Int.self, forColumn: "idx"),
            rootTag: try row.decode(Int64.self, forColumn: "rootTag"),
            createdAt: try row.decode(Int64.self, forColumn: "createdAt")
        )
    }
}
