import GRDB
public import KnitStore

/// The ``OwnProfileStore`` on SQLite: the one row of `own_profile`.
///
/// If the row cannot be read, ``load()`` answers a fresh profile. Its version is 0, so no peer takes its empty
/// name over the one it holds: presentation follows the newest version (`.agents/context/custody.md`).
public final class SQLOwnProfileStore: OwnProfileStore {
    private let database: KnitDatabase

    /// Our own profile in `database`.
    public init(_ database: KnitDatabase) {
        self.database = database
    }

    public func load() -> OwnProfile {
        database.read(or: OwnProfile()) { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT name, status, openToChat, version, publishedAt FROM own_profile WHERE slot = 0"
                )
            else {
                return OwnProfile()
            }
            return OwnProfile(
                name: try row.text("name"),
                status: try row.text("status"),
                openToChat: try row.decode(Bool.self, forColumn: "openToChat"),
                version: try row.decode(Int64.self, forColumn: "version"),
                publishedAt: try row.decode(Int64.self, forColumn: "publishedAt")
            )
        }
    }

    public func save(_ profile: OwnProfile) {
        database.write(or: ()) { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO own_profile (slot, name, status, openToChat, version, publishedAt)
                    VALUES (0, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    StoredText.bytes(profile.name), StoredText.bytes(profile.status), profile.openToChat, profile.version,
                    profile.publishedAt,
                ]
            )
        }
    }
}
