import Foundation
import GRDB
public import KnitStore
public import KnitWire

/// The ``PeerStore`` on SQLite: the `peers` table, and `peer_profiles` beside it (`PeerDao.kt` in knit-next).
///
/// `peer_profiles` holds the signed frame each pin came from, in a table of its own as knit-next keeps it. Nothing
/// in this port deletes a pin yet. A door that does must delete its `peer_profiles` row too, as knit-next's sweeps
/// do, so the proof never outlives the pin it proves.
public final class SQLPeerStore: PeerStore {
    /// Every column of a peer, in the order ``upsert(_:)`` binds them. `INSERT OR REPLACE` writes a whole row, so a
    /// column missing here would be nulled by every write: the photo hashes and the prekey are here for that reason.
    private static let columns =
        "nodeId, name, status, publicKey, deviceTag, protocolVersion, capabilities, updatedAt, verified, openToChat, avatarHash, "
        + "advertisedAvatarHash, prekeyId, prekeyPub, prekeySig, prekeyProfileAt"

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
                sql: "INSERT OR REPLACE INTO peers (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    StoredText.bytes(peer.nodeId.string), StoredText.bytes(peer.name), StoredText.bytes(peer.status),
                    StoredText.bytes(peer.publicKey), StoredText.bytes(peer.deviceTag), peer.protocolVersion, peer.capabilities,
                    peer.updatedAt, peer.verified, peer.openToChat, StoredText.bytes(peer.avatarHash?.string),
                    StoredText.bytes(peer.advertisedAvatarHash?.string), peer.prekey?.id, peer.prekey.map { Data($0.pub) },
                    peer.prekey.map { Data($0.sig) }, peer.prekeyProfileAt,
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
            prekeyProfileAt: try row.decode(Int64.self, forColumn: "prekeyProfileAt")
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
