import Foundation
import GRDB
public import KnitStore
public import KnitWire

/// The ``OwnProfileStore`` on SQLite: the one row of `own_profile`, and the one row of `own_profile_frame` beside it.
///
/// If the row cannot be read, ``load()`` answers a fresh profile. Its version is 0, so no peer takes its empty
/// name over the one it holds: presentation follows the newest version (`.agents/context/custody.md`).
/// ``loadIfReadable()`` answers `nil` then, for a caller that must not take a failed read for a fresh profile, and
/// ``keptFrame()`` answers ``KeptProfileFrame/unreadable``, never "none kept".
public final class SQLOwnProfileStore: OwnProfileStore {
    private let database: KnitDatabase

    /// Our own profile in `database`.
    public init(_ database: KnitDatabase) {
        self.database = database
    }

    public func load() -> OwnProfile {
        loadIfReadable() ?? OwnProfile()
    }

    /// The row, a fresh profile when there is none yet, or `nil` when the read failed, which ``KnitDatabase`` has
    /// reported.
    public func loadIfReadable() -> OwnProfile? {
        database.read(or: OwnProfile?.none) { db -> OwnProfile? in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT name, status, openToChat, version, publishedAt, avatarHash, prekeyId, capabilities
                        FROM own_profile WHERE slot = 0
                        """
                )
            else {
                return OwnProfile()
            }
            return OwnProfile(
                name: try row.text("name"),
                status: try row.text("status"),
                openToChat: try row.decode(Bool.self, forColumn: "openToChat"),
                version: try row.decode(Int64.self, forColumn: "version"),
                publishedAt: try row.decode(Int64.self, forColumn: "publishedAt"),
                avatarHash: try row.optionalBlobHash("avatarHash"),
                prekeyId: try row.decode(Int?.self, forColumn: "prekeyId"),
                capabilities: try row.decode(Int64?.self, forColumn: "capabilities").map(Capabilities.init(rawValue:))
            )
        }
    }

    /// Writes the whole row. `INSERT OR REPLACE` nulls any column it does not name, so every column is named here,
    /// the photo's, the prekey's and the capabilities' included: a republish that left one out would drop it.
    public func save(_ profile: OwnProfile) {
        database.write(or: ()) { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO own_profile
                        (slot, name, status, openToChat, version, publishedAt, avatarHash, prekeyId, capabilities)
                    VALUES (0, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    StoredText.bytes(profile.name), StoredText.bytes(profile.status), profile.openToChat, profile.version,
                    profile.publishedAt, StoredText.bytes(profile.avatarHash?.string), profile.prekeyId, profile.capabilities?.rawValue,
                ]
            )
        }
    }

    /// The kept frame's row, none, or ``KeptProfileFrame/unreadable`` when the read failed, which ``KnitDatabase`` has
    /// reported. Inside a store unit the failure fails the unit too.
    public func keptFrame() -> KeptProfileFrame {
        database.read(or: KeptProfileFrame.unreadable) { db -> KeptProfileFrame in
            guard let row = try Row.fetchOne(db, sql: "SELECT sig, signed FROM own_profile_frame WHERE slot = 0") else {
                return .absent
            }
            return .kept(WireEnvelope(sig: try row.bytes("sig"), signed: try row.bytes("signed")))
        }
    }

    /// Writes the kept frame's row, or deletes it for `nil`. Both columns are bound as `Data`, so every byte, a NUL
    /// included, is stored as it came, and a `STRICT` table refuses anything bound as text.
    @discardableResult
    public func keep(_ frame: WireEnvelope?) -> Bool {
        database.write(or: false) { db in
            if let frame {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO own_profile_frame (slot, sig, signed) VALUES (0, ?, ?)",
                    arguments: [Data(frame.sig), Data(frame.signed)]
                )
            } else {
                try db.execute(sql: "DELETE FROM own_profile_frame WHERE slot = 0")
            }
            return true
        }
    }
}
