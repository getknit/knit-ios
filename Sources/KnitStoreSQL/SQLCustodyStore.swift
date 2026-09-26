import Foundation
import GRDB
public import KnitStore
import KnitWire

/// The ``CustodyStore`` on SQLite: the `forward_store` table (`ForwardDao.kt` in knit-next).
///
/// It applies ``CustodyRules`` exactly as ``MemoryCustodyStore`` does, and both run the same contract tests, so
/// the iPhone carries the same newest-N set as every other node. The rules run in Swift over the live rows, not
/// as SQL of their own, so there is one copy of the law to keep in step with Android's.
///
/// Only the originator's bytes and the columns the rules and queries read are stored. The envelope is decoded
/// from ``CarriedFrame/signed`` on the way out, as knit-next does, so a stored frame can never disagree with
/// the bytes its signature covers.
public final class SQLCustodyStore: CustodyStore {
    private let database: KnitDatabase
    private let limits: CustodyLimits

    /// The custody table in `database`, with knit-next's limits unless told otherwise.
    public init(_ database: KnitDatabase, limits: CustodyLimits = CustodyLimits()) {
        self.database = database
        self.limits = limits
    }

    @discardableResult
    public func store(_ frame: CarriedFrame, origin: CustodyOrigin, now: Int64) -> Bool {
        guard let expiresAt = CustodyRules.expiry(of: frame.envelope, now: now, limits: limits) else {
            return false
        }
        let entry = CustodyRules.Entry(frame.envelope, expiresAt: expiresAt)
        let envelope = frame.envelope
        return database.write(or: false) { db in
            try db.execute(
                sql: """
                    INSERT INTO forward_store
                        (id, senderId, recipientId, groupId, type, isRoomChat, origin, signed, sig, sentAt, receivedAt, expiresAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO NOTHING
                    """,
                arguments: [
                    StoredText.bytes(envelope.id), StoredText.bytes(envelope.senderId), StoredText.bytes(envelope.recipientId),
                    StoredText.bytes(envelope.group?.id), StoredText.bytes(envelope.type.rawValue), entry.isRoomChat,
                    origin.code, Data(frame.signed), Data(frame.sig), envelope.sentAt, now, expiresAt,
                ]
            )
            // A frame already held, live or not yet swept, is left as it is.
            guard db.changesCount > 0 else {
                return true
            }
            let live = try Row.fetchAll(
                db,
                sql: "SELECT id, senderId, groupId, isRoomChat, sentAt, expiresAt FROM forward_store WHERE expiresAt >= ?",
                arguments: [now]
            ).map(Self.entry)
            for id in CustodyRules.evictions(after: entry, among: live, limits: limits) {
                try db.execute(sql: "DELETE FROM forward_store WHERE id = ?", arguments: [StoredText.bytes(id)])
            }
            return true
        }
    }

    public func liveFrames(now: Int64) -> [CarriedFrame] {
        database.read(or: []) { db in
            try Row.fetchAll(
                db,
                sql: "SELECT sig, signed FROM forward_store WHERE expiresAt >= ? ORDER BY receivedAt DESC, seq DESC",
                arguments: [now]
            ).compactMap(Self.frame)
        }
    }

    public func liveIds(now: Int64) -> [String] {
        database.read(or: []) { db in
            try Row.fetchAll(db, sql: "SELECT id FROM forward_store WHERE expiresAt >= ? ORDER BY seq", arguments: [now])
                .map { try $0.text("id") }
        }
    }

    public func frame(_ id: String, now: Int64) -> CarriedFrame? {
        database.read(or: nil) { db in
            try Row.fetchOne(
                db,
                sql: "SELECT sig, signed FROM forward_store WHERE id = ? AND expiresAt >= ?",
                arguments: [StoredText.bytes(id), now]
            ).flatMap(Self.frame)
        }
    }

    public func contains(_ id: String) -> Bool {
        database.read(or: false) { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM forward_store WHERE id = ?)",
                arguments: [StoredText.bytes(id)]
            ) ?? false
        }
    }

    public func recipient(of id: String) -> String? {
        database.read(or: nil) { db in
            try Row.fetchOne(db, sql: "SELECT recipientId FROM forward_store WHERE id = ?", arguments: [StoredText.bytes(id)])?
                .optionalText("recipientId")
        }
    }

    public func remove(_ id: String) {
        database.write(or: ()) { db in
            try db.execute(sql: "DELETE FROM forward_store WHERE id = ?", arguments: [StoredText.bytes(id)])
        }
    }

    @discardableResult
    public func sweepExpired(now: Int64) -> Int {
        database.write(or: 0) { db in
            try db.execute(sql: "DELETE FROM forward_store WHERE expiresAt < ?", arguments: [now])
            return db.changesCount
        }
    }

    /// What the quotas read of a row.
    private static func entry(_ row: Row) throws -> CustodyRules.Entry {
        CustodyRules.Entry(
            id: try row.text("id"),
            senderId: try row.text("senderId"),
            groupId: try row.optionalText("groupId"),
            isRoomChat: try row.decode(Bool.self, forColumn: "isRoomChat"),
            sentAt: try row.decode(Int64.self, forColumn: "sentAt"),
            expiresAt: try row.decode(Int64.self, forColumn: "expiresAt")
        )
    }

    /// The frame in a row of `sig` and `signed`, or `nil` if its bytes no longer decode, which only a damaged file
    /// can do: they decoded on the way in.
    private static func frame(_ row: Row) throws -> CarriedFrame? {
        let signed = try row.bytes("signed")
        guard let envelope = try? RelayEnvelope(decoding: signed) else {
            return nil
        }
        return CarriedFrame(envelope: envelope, sig: try row.bytes("sig"), signed: signed)
    }
}

extension CustodyOrigin {
    /// The stored value: knit-next's `ORIGIN_RELAY` and `ORIGIN_SELF`.
    var code: Int {
        switch self {
        case .relayed:
            0
        case .own:
            1
        }
    }
}
