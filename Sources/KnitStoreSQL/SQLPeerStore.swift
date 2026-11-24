import Foundation
import GRDB
public import KnitStore
public import KnitWire

/// The ``PeerStore`` on SQLite: the `peers` table, and `peer_profiles` beside it (`PeerDao.kt` in knit-next).
///
/// `peer_profiles` holds the signed frame each pin came from, in a table of its own as knit-next keeps it. Nothing
/// in this port deletes a pin yet. A door that does must delete its `peer_profiles` row too, as knit-next's sweeps
/// do, so the proof never outlives the pin it proves. A proof can go before its pin: the sweep deletes one longer than
/// custody's profile cap (``deleteProfileFrames(longerThan:)``, ADR 2026-10.r88m), and the pin stays.
public final class SQLPeerStore: PeerStore {
    /// Every column of a peer, in the order ``upsert(_:)`` binds them. The upsert writes a whole row, so a column missing
    /// here would be reset by every write: the photo hashes, the prekey and `lastSeenAt` are here for that reason.
    private static let columns =
        "nodeId, name, status, publicKey, deviceTag, protocolVersion, capabilities, updatedAt, verified, openToChat, avatarHash, "
        + "advertisedAvatarHash, prekeyId, prekeyPub, prekeySig, prekeyProfileAt, lastSeenAt"

    /// The upsert's conflict clause: every column but the key takes the row written, and `lastSeenAt` the larger of the two,
    /// as `PeerDao.upsertRow` merges it (knit-next ADR 2026-10.k8ge), so a read-copy-write never takes back a stamp
    /// ``markSeen(_:gate:)`` banked after the read. An upsert, not `INSERT OR REPLACE`, which deletes the row first.
    private static let upsertSQL =
        "INSERT INTO peers (\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
        + "ON CONFLICT (nodeId) DO UPDATE SET "
        + "name = excluded.name, status = excluded.status, publicKey = excluded.publicKey, deviceTag = excluded.deviceTag, "
        + "protocolVersion = excluded.protocolVersion, capabilities = excluded.capabilities, updatedAt = excluded.updatedAt, "
        + "verified = excluded.verified, openToChat = excluded.openToChat, avatarHash = excluded.avatarHash, "
        + "advertisedAvatarHash = excluded.advertisedAvatarHash, prekeyId = excluded.prekeyId, prekeyPub = excluded.prekeyPub, "
        + "prekeySig = excluded.prekeySig, prekeyProfileAt = excluded.prekeyProfileAt, "
        + "lastSeenAt = MAX(peers.lastSeenAt, excluded.lastSeenAt)"

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
                sql: Self.upsertSQL,
                arguments: [
                    StoredText.bytes(peer.nodeId.string), StoredText.bytes(peer.name), StoredText.bytes(peer.status),
                    StoredText.bytes(peer.publicKey), StoredText.bytes(peer.deviceTag), peer.protocolVersion, peer.capabilities,
                    peer.updatedAt, peer.verified, peer.openToChat, StoredText.bytes(peer.avatarHash?.string),
                    StoredText.bytes(peer.advertisedAvatarHash?.string), peer.prekey?.id, peer.prekey.map { Data($0.pub) },
                    peer.prekey.map { Data($0.sig) }, peer.prekeyProfileAt, peer.lastSeenAt,
                ]
            )
        }
    }

    public func markSeen(_ stamps: [NodeId: Int64], gate: Int64) -> Set<NodeId>? {
        // One transaction for the whole bank, as `PeerRepository.flushSeen` writes it. The threshold is overflow-checked
        // (``PeerRecord/seenThreshold(at:gate:)``), the same as the memory store's.
        database.write(or: nil) { db -> Set<NodeId>? in
            var changed: Set<NodeId> = []
            for (nodeId, at) in stamps {
                guard let olderThan = PeerRecord.seenThreshold(at: at, gate: gate) else {
                    continue
                }
                try db.execute(
                    sql: "UPDATE peers SET lastSeenAt = ? WHERE nodeId = ? AND lastSeenAt < ?",
                    arguments: [at, StoredText.bytes(nodeId.string), olderThan]
                )
                if db.changesCount > 0 {
                    changed.insert(nodeId)
                }
            }
            return changed
        }
    }

    public func lastSeenStamps() -> [NodeId: Int64] {
        database.read(or: [:]) { db in
            var stamps: [NodeId: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT nodeId, lastSeenAt FROM peers") {
                stamps[try row.nodeId("nodeId")] = try row.decode(Int64.self, forColumn: "lastSeenAt")
            }
            return stamps
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

    public func recordProfileFrame(_ frame: WireEnvelope, of nodeId: NodeId, sentAt: Int64) {
        // An upsert that only ever moves forward, not INSERT OR REPLACE: a copy we already hold is never rewritten.
        database.write(or: ()) { db in
            try db.execute(
                sql: """
                    INSERT INTO peer_profiles (nodeId, signed, sig, sentAt) VALUES (?, ?, ?, ?)
                    ON CONFLICT (nodeId) DO UPDATE SET signed = excluded.signed, sig = excluded.sig, sentAt = excluded.sentAt
                    WHERE excluded.sentAt > peer_profiles.sentAt
                    """,
                arguments: [StoredText.bytes(nodeId.string), Data(frame.signed), Data(frame.sig), sentAt]
            )
        }
    }

    public func profileFrame(of nodeId: NodeId) -> WireEnvelope? {
        database.read(or: nil) { db in
            try Row.fetchOne(
                db,
                sql: "SELECT signed, sig FROM peer_profiles WHERE nodeId = ?",
                arguments: [StoredText.bytes(nodeId.string)]
            ).map { WireEnvelope(relay: false, sig: try $0.bytes("sig"), signed: try $0.bytes("signed")) }
        }
    }

    public func deleteProfileFrames(longerThan maxSignedBytes: Int) -> Int {
        // `signed` is a BLOB in a STRICT table, so `length` counts its bytes, as the custody sweep's byte cap does.
        database.write(or: 0) { db in
            try db.execute(sql: "DELETE FROM peer_profiles WHERE length(signed) > ?", arguments: [maxSignedBytes])
            return db.changesCount
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
            openToChat: try row.decode(Bool.self, forColumn: "openToChat"),
            avatarHash: try row.optionalBlobHash("avatarHash"),
            advertisedAvatarHash: try row.optionalBlobHash("advertisedAvatarHash"),
            prekey: try prekey(row),
            prekeyProfileAt: try row.decode(Int64.self, forColumn: "prekeyProfileAt"),
            lastSeenAt: try row.decode(Int64.self, forColumn: "lastSeenAt")
        )
    }

    /// The peer's prekey in a row of ``columns``, or `nil` unless all three of its columns hold one.
    private static func prekey(_ row: Row) throws -> PrekeyInfo? {
        guard let id = try row.decode(Int?.self, forColumn: "prekeyId"), let pub = try row.decode(Data?.self, forColumn: "prekeyPub"),
            let sig = try row.decode(Data?.self, forColumn: "prekeySig")
        else {
            return nil
        }
        return PrekeyInfo(id: id, pub: [UInt8](pub), sig: [UInt8](sig))
    }
}
