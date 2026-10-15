import GRDB
public import KnitStore
import KnitWire

/// The ``OwnProfileStore`` on SQLite: the one row of `own_profile`.
///
/// If the row cannot be read, ``load()`` answers a fresh profile. Its version is 0, so no peer takes its empty
/// name over the one it holds: presentation follows the newest version (`.agents/context/custody.md`).
/// ``loadIfReadable()`` answers `nil` then, for a caller that must not take a failed read for a fresh profile.
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
                    sql: "SELECT name, status, openToChat, version, publishedAt, avatarHash, prekeyId FROM own_profile WHERE slot = 0"
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
                prekeyId: try row.decode(Int?.self, forColumn: "prekeyId")
            )
        }
    }

    /// Writes the whole row. `INSERT OR REPLACE` nulls any column it does not name, so every column is named here,
    /// the photo's and the prekey's included: a republish that left one out would drop it.
    public func save(_ profile: OwnProfile) {
        database.write(or: ()) { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO own_profile (slot, name, status, openToChat, version, publishedAt, avatarHash, prekeyId)
                    VALUES (0, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    StoredText.bytes(profile.name), StoredText.bytes(profile.status), profile.openToChat, profile.version,
                    profile.publishedAt, StoredText.bytes(profile.avatarHash?.string), profile.prekeyId,
                ]
            )
        }
    }
}
