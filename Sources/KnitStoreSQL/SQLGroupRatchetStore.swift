import Foundation
import GRDB
public import KnitStore
public import KnitWire

/// The ``GroupRatchetStore`` on SQLite: `group_send_chains`, `group_recv_chains`, `group_skipped_keys` and
/// `group_key_sends` (schema v18, ADR 2026-10.5sk9), with `GroupRatchetDao`'s row rules (knit-next
/// `data/ratchet/GroupRatchetDao.kt:16-123`): a send chain, a receive chain and an outbox row are `INSERT OR REPLACE`, a
/// skipped key `INSERT OR IGNORE`, and a spent key goes by its full key, the mint included, where Kotlin's takes every
/// mint's key at its index (knit-next #177). Every group, sender and member id is its UTF-8 bytes in a `BLOB`
/// (``StoredText``), so ids compare by their bytes, and read back whole (ADR 2026-09.jc2x).
///
/// Each write is one transaction of its own outside a store unit, and one savepoint inside it, so an open's rows land
/// together or not at all either way. The sweep applies ``GroupRatchetRetention`` in Swift over what it reads, as
/// ``SQLRatchetStore`` applies ``RatchetRetention``, so this store and ``MemoryGroupRatchetStore`` retire the same rows.
/// What it deletes is zeroed in the next write of its page (`secure_delete`, ``KnitDatabase``), and once the sweep
/// commits, the DM sweep's truncating checkpoint copies those pages over the file and empties the write-ahead log,
/// unless a reader holds a snapshot of the log then (``SQLRatchetStore/truncateLog(_:reporting:)``).
public final class SQLGroupRatchetStore: GroupRatchetStore {
    private static let sendColumns = "epoch, seed, chainKey, count, mintedAt"
    private static let recvColumns = "epoch, mintedAt, chainKey, next, lastUsedAt"
    private static let skippedColumns = "epoch, mintedAt, idx, msgKey, createdAt"
    private static let outboxColumns = "memberId, sentEpoch, sentAt, ackedEpoch, ackedAt"

    private let database: KnitDatabase

    /// The group form's rows in `database`.
    public init(_ database: KnitDatabase) {
        self.database = database
    }

    public func sendChain(_ group: String) -> GroupSendChainRecord? {
        database.read(or: nil) { db in
            try Row.fetchOne(
                db,
                sql: "SELECT \(Self.sendColumns) FROM group_send_chains WHERE groupId = ? ORDER BY epoch DESC LIMIT 1",
                arguments: [StoredText.bytes(group)]
            ).map(Self.sendChain)
        }
    }

    public func sendChains(_ group: String) -> [GroupSendChainRecord] {
        // Retired rows are left out here rather than in the query, as `GroupRatchetRepository.sendChains` filters them: the
        // sweep reads every row, and a retired one counts there as the newest.
        database.read(or: []) { db in
            try Self.allSendChains(StoredText.bytes(group), in: db).filter { !$0.isRetired }
        }
    }

    public func commitSend(_ chain: GroupSendChainRecord, in group: String) {
        database.write(or: ()) { db in
            try Self.upsert(chain, in: StoredText.bytes(group), db)
        }
    }

    public func retireSendChains(_ group: String) {
        database.write(or: ()) { db in
            try Self.retireSendChains(StoredText.bytes(group), in: db)
        }
    }

    public func recvChains(_ group: String, from sender: NodeId, epoch: Int) -> [GroupRecvChainRecord] {
        database.read(or: []) { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.recvColumns) FROM group_recv_chains WHERE groupId = ? AND senderId = ? AND epoch = ?
                    ORDER BY mintedAt DESC
                    """,
                arguments: [StoredText.bytes(group), StoredText.bytes(sender.string), epoch]
            ).map(Self.recvChain)
        }
    }

    public func skippedKeys(_ group: String, from sender: NodeId, epoch: Int, index: Int) -> [GroupSkippedKeyRecord] {
        database.read(or: []) { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.skippedColumns) FROM group_skipped_keys
                    WHERE groupId = ? AND senderId = ? AND epoch = ? AND idx = ? ORDER BY mintedAt DESC
                    """,
                arguments: [StoredText.bytes(group), StoredText.bytes(sender.string), epoch, index]
            ).map(Self.skippedKey)
        }
    }

    public func insertRecvChain(_ chain: GroupRecvChainRecord, in group: String, from sender: NodeId) {
        database.write(or: ()) { db in
            try Self.upsert(chain, in: StoredText.bytes(group), from: StoredText.bytes(sender.string), db)
        }
    }

    public func applyOpen(_ delta: GroupOpenDelta, in group: String, from sender: NodeId, se: Int, n: Int) {
        // The whole delta in one write, in `GroupRatchetRepository.applyOpen`'s order (`GroupRatchetRepository.kt:74-98`).
        database.write(or: ()) { db in
            let groupId = StoredText.bytes(group)
            let senderId = StoredText.bytes(sender.string)
            if let chain = delta.recvChain {
                try Self.upsert(chain, in: groupId, from: senderId, db)
            }
            for key in delta.skippedInserts {
                try db.execute(
                    sql:
                        "INSERT OR IGNORE INTO group_skipped_keys (groupId, senderId, \(Self.skippedColumns)) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    arguments: [groupId, senderId, key.epoch, key.mintedAt, key.index, Data(key.messageKey), key.createdAt]
                )
            }
            if let mintedAt = delta.consumedSkippedMintedAt {
                // The spent key by its full key; Kotlin's takes every mint's key at the index (`GroupRatchetDao.kt:77-84`).
                try db.execute(
                    sql: "DELETE FROM group_skipped_keys WHERE groupId = ? AND senderId = ? AND epoch = ? AND mintedAt = ? AND idx = ?",
                    arguments: [groupId, senderId, se, mintedAt, n]
                )
            }
        }
    }

    public func purgeGroup(_ group: String) {
        database.write(or: ()) { db in
            let groupId = StoredText.bytes(group)
            try Self.retireSendChains(groupId, in: db)
            for table in ["group_recv_chains", "group_skipped_keys", "group_key_sends"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE groupId = ?", arguments: [groupId])
            }
        }
    }

    public func keySend(_ group: String, member: NodeId) -> GroupKeySendRecord? {
        database.read(or: nil) { db in
            try Self.keySend(StoredText.bytes(group), member: StoredText.bytes(member.string), in: db)
        }
    }

    public func keySends(_ group: String) -> [GroupKeySendRecord] {
        database.read(or: []) { db in
            try Self.keySends(StoredText.bytes(group), in: db)
        }
    }

    public func markKeySent(_ group: String, to member: NodeId, epoch: Int, at: Int64) {
        database.write(or: ()) { db in
            let groupId = StoredText.bytes(group)
            let memberId = StoredText.bytes(member.string)
            let held = try Self.keySend(groupId, member: memberId, in: db)
            let row = GroupKeySendRecord(
                member: member,
                sentEpoch: max(epoch, held?.sentEpoch ?? 0),
                sentAt: at,
                ackedEpoch: held?.ackedEpoch ?? 0,
                ackedAt: held?.ackedAt ?? 0
            )
            try Self.upsert(row, in: groupId, db)
        }
    }

    public func markKeyAcked(_ group: String, by member: NodeId, epoch: Int, at: Int64) {
        database.write(or: ()) { db in
            let groupId = StoredText.bytes(group)
            guard var row = try Self.keySend(groupId, member: StoredText.bytes(member.string), in: db), epoch > row.ackedEpoch else {
                return
            }
            row.ackedEpoch = epoch
            row.ackedAt = at
            try Self.upsert(row, in: groupId, db)
        }
    }

    public func deleteKeySend(_ group: String, member: NodeId) {
        database.write(or: ()) { db in
            try db.execute(
                sql: "DELETE FROM group_key_sends WHERE groupId = ? AND memberId = ?",
                arguments: [StoredText.bytes(group), StoredText.bytes(member.string)]
            )
        }
    }

    public func holdings(of group: String) -> GroupRatchetHoldings {
        database.read(or: .empty) { db in
            let groupId = StoredText.bytes(group)
            var recvChains: [NodeId: [GroupRecvChainRecord]] = [:]
            let chains = try Row.fetchAll(
                db,
                sql: "SELECT senderId, \(Self.recvColumns) FROM group_recv_chains WHERE groupId = ? ORDER BY epoch, mintedAt",
                arguments: [groupId]
            )
            for row in chains {
                recvChains[try row.nodeId("senderId"), default: []].append(try Self.recvChain(row))
            }
            var skippedKeys: [NodeId: [GroupSkippedKeyRecord]] = [:]
            let keys = try Row.fetchAll(
                db,
                sql: "SELECT senderId, \(Self.skippedColumns) FROM group_skipped_keys WHERE groupId = ? ORDER BY epoch, mintedAt, idx",
                arguments: [groupId]
            )
            for row in keys {
                skippedKeys[try row.nodeId("senderId"), default: []].append(try Self.skippedKey(row))
            }
            return GroupRatchetHoldings(
                sendChains: try Self.allSendChains(groupId, in: db),
                recvChains: recvChains,
                skippedKeys: skippedKeys,
                outbox: try Self.keySends(groupId, in: db)
            )
        }
    }

    public func sweep(now: Int64) {
        // `GroupRatchetRepository.sweep`'s order (`GroupRatchetRepository.kt:154-160`), in one write.
        database.write(or: ()) { [database] db in
            try db.execute(
                sql: "DELETE FROM group_skipped_keys WHERE createdAt < ?",
                arguments: [GroupRatchetRetention.skippedKeyCutoff(now: now)]
            )
            let held = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM group_skipped_keys") ?? 0
            if GroupRatchetRetention.skippedKeyExcess(count: held) > 0 {
                try Self.evictSkippedKeys(in: db)
            }
            try db.execute(
                sql: "DELETE FROM group_recv_chains WHERE lastUsedAt < ?",
                arguments: [GroupRatchetRetention.receiveChainCutoff(now: now)]
            )
            try Self.sweepSendChains(now: now, in: db)
            // The zeros are in the pages this write puts in the log, which the truncating checkpoint copies over the file
            // and empties once the outermost transaction this write joined commits, never on a rollback.
            db.afterNextTransaction { db in
                SQLRatchetStore.truncateLog(db, reporting: database)
            }
        }
    }
}

// The statements and row readers, apart from the class only to keep its body inside the lint's length.
extension SQLGroupRatchetStore {
    /// Every send chain for `groupId`, retired rows included, the newest epoch first (`sendChains`, `GroupRatchetDao.kt:22-23`).
    private static func allSendChains(_ groupId: Data, in db: Database) throws -> [GroupSendChainRecord] {
        try Row.fetchAll(
            db,
            sql: "SELECT \(sendColumns) FROM group_send_chains WHERE groupId = ? ORDER BY epoch DESC",
            arguments: [groupId]
        ).map(sendChain)
    }

    /// Every send chain for `groupId` gone, the newest back as a retired row (`retireSendChains`,
    /// `GroupRatchetRepository.kt:42-46`); nothing, when we never minted.
    private static func retireSendChains(_ groupId: Data, in db: Database) throws {
        guard let newest = try allSendChains(groupId, in: db).first else {
            return
        }
        try db.execute(sql: "DELETE FROM group_send_chains WHERE groupId = ?", arguments: [groupId])
        try upsert(GroupRatchetRetention.retired(newest), in: groupId, db)
    }

    /// Each group's superseded send chains, below the lowest epoch it keeps (`sweepSendChains`,
    /// `GroupRatchetRepository.kt:162-181`).
    private static func sweepSendChains(now: Int64, in db: Database) throws {
        let newest = try Row.fetchAll(
            db,
            sql: """
                SELECT groupId, epoch, mintedAt FROM group_send_chains AS chain
                WHERE epoch = (SELECT MAX(epoch) FROM group_send_chains WHERE groupId = chain.groupId)
                """
        )
        for row in newest {
            let lowest = GroupRatchetRetention.lowestKeptEpoch(
                newest: try row.decode(Int.self, forColumn: "epoch"),
                mintedAt: try row.decode(Int64.self, forColumn: "mintedAt"),
                now: now
            )
            try db.execute(
                sql: "DELETE FROM group_send_chains WHERE groupId = ? AND epoch < ?",
                arguments: [try row.decode(Data.self, forColumn: "groupId"), lowest]
            )
        }
    }

    /// The skipped keys past the cap, evicted as the memory store evicts them, tiebreak included. Each goes by the key
    /// bytes it was read with, never a string made of them again.
    private static func evictSkippedKeys(in db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT groupId, senderId, epoch, mintedAt, idx, createdAt FROM group_skipped_keys")
        let held = try rows.map { row in
            HeldKey(
                groupId: try row.decode(Data.self, forColumn: "groupId"),
                senderId: try row.decode(Data.self, forColumn: "senderId"),
                stamp: GroupSkippedKeyStamp(
                    group: ExactKey(try row.text("groupId")),
                    sender: try row.nodeId("senderId"),
                    epoch: try row.decode(Int.self, forColumn: "epoch"),
                    mintedAt: try row.decode(Int64.self, forColumn: "mintedAt"),
                    index: try row.decode(Int.self, forColumn: "idx"),
                    createdAt: try row.decode(Int64.self, forColumn: "createdAt")
                )
            )
        }
        let evicted = Set(GroupRatchetRetention.evictedSkippedKeys(held.map(\.stamp)))
        for key in held where evicted.contains(key.stamp) {
            try db.execute(
                sql: "DELETE FROM group_skipped_keys WHERE groupId = ? AND senderId = ? AND epoch = ? AND mintedAt = ? AND idx = ?",
                arguments: [key.groupId, key.senderId, key.stamp.epoch, key.stamp.mintedAt, key.stamp.index]
            )
        }
    }

    /// A stored key as the cap weighs it, beside the key columns' bytes as read.
    private struct HeldKey {
        let groupId: Data
        let senderId: Data
        let stamp: GroupSkippedKeyStamp
    }

    /// A retired chain's seed and chain key are empty. GRDB binds a `Data` through its bytes' pointer, which SQLite takes
    /// as `NULL` when it is nil: swift-foundation's empty `Data` hands a pointer, and a Foundation that hands none would
    /// break Kotlin's `NOT NULL` columns. The `coalesce` stores the empty blob Room stores for a `ByteArray(0)` either way.
    private static func upsert(_ chain: GroupSendChainRecord, in groupId: Data, _ db: Database) throws {
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO group_send_chains (groupId, \(sendColumns))
                VALUES (?, ?, coalesce(?, X''), coalesce(?, X''), ?, ?)
                """,
            arguments: [groupId, chain.epoch, Data(chain.seed), Data(chain.chainKey), chain.count, chain.mintedAt]
        )
    }

    private static func upsert(_ chain: GroupRecvChainRecord, in groupId: Data, from senderId: Data, _ db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO group_recv_chains (groupId, senderId, \(recvColumns)) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [groupId, senderId, chain.epoch, chain.mintedAt, Data(chain.chainKey), chain.next, chain.lastUsedAt]
        )
    }

    private static func upsert(_ row: GroupKeySendRecord, in groupId: Data, _ db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO group_key_sends (groupId, \(outboxColumns)) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [groupId, StoredText.bytes(row.member.string), row.sentEpoch, row.sentAt, row.ackedEpoch, row.ackedAt]
        )
    }

    private static func keySend(_ groupId: Data, member memberId: Data, in db: Database) throws -> GroupKeySendRecord? {
        try Row.fetchOne(
            db,
            sql: "SELECT \(outboxColumns) FROM group_key_sends WHERE groupId = ? AND memberId = ?",
            arguments: [groupId, memberId]
        ).map(keySend)
    }

    /// Every outbox row for `groupId`, in member order: a node id's bytes order as its text does.
    private static func keySends(_ groupId: Data, in db: Database) throws -> [GroupKeySendRecord] {
        try Row.fetchAll(
            db,
            sql: "SELECT \(outboxColumns) FROM group_key_sends WHERE groupId = ? ORDER BY memberId",
            arguments: [groupId]
        ).map(keySend)
    }

    private static func sendChain(_ row: Row) throws -> GroupSendChainRecord {
        GroupSendChainRecord(
            epoch: try row.decode(Int.self, forColumn: "epoch"),
            seed: try row.bytes("seed"),
            chainKey: try row.bytes("chainKey"),
            count: try row.decode(Int.self, forColumn: "count"),
            mintedAt: try row.decode(Int64.self, forColumn: "mintedAt")
        )
    }

    private static func recvChain(_ row: Row) throws -> GroupRecvChainRecord {
        GroupRecvChainRecord(
            epoch: try row.decode(Int.self, forColumn: "epoch"),
            mintedAt: try row.decode(Int64.self, forColumn: "mintedAt"),
            chainKey: try row.bytes("chainKey"),
            next: try row.decode(Int.self, forColumn: "next"),
            lastUsedAt: try row.decode(Int64.self, forColumn: "lastUsedAt")
        )
    }

    private static func skippedKey(_ row: Row) throws -> GroupSkippedKeyRecord {
        GroupSkippedKeyRecord(
            epoch: try row.decode(Int.self, forColumn: "epoch"),
            mintedAt: try row.decode(Int64.self, forColumn: "mintedAt"),
            index: try row.decode(Int.self, forColumn: "idx"),
            messageKey: try row.bytes("msgKey"),
            createdAt: try row.decode(Int64.self, forColumn: "createdAt")
        )
    }

    private static func keySend(_ row: Row) throws -> GroupKeySendRecord {
        GroupKeySendRecord(
            member: try row.nodeId("memberId"),
            sentEpoch: try row.decode(Int.self, forColumn: "sentEpoch"),
            sentAt: try row.decode(Int64.self, forColumn: "sentAt"),
            ackedEpoch: try row.decode(Int.self, forColumn: "ackedEpoch"),
            ackedAt: try row.decode(Int64.self, forColumn: "ackedAt")
        )
    }
}
