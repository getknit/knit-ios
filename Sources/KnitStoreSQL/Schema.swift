import GRDB

/// The database's schema, as an append-only list of migrations (`KnitMigrations.kt` in knit-next).
///
/// **v1 is the frozen baseline.** A migration, once committed, is never edited, reordered or removed: a phone
/// that already ran it would keep the old shape while a fresh install got the new one. Every change is a new
/// migration at the end, with a test that migrates rows written under the old shape. `SchemaTests` pins the
/// identifiers and the schema each one leaves behind (ADR 2026-09.nyya).
///
/// Every table is `STRICT`, and every string is stored as its UTF-8 bytes in a `BLOB` column, never as `TEXT`:
/// GRDB binds a Swift `String` NUL-terminated, which would cut an id at its first NUL and make it collide with
/// its own prefix. A `STRICT` table refuses a `TEXT` value in a `BLOB` column, so a string bound by mistake
/// fails loudly instead of keying a row by the wrong bytes (``StoredText``).
///
/// The statements are written out rather than built with GRDB's table builder, so a GRDB upgrade cannot change
/// the text a fresh install gets.
internal enum Schema {
    /// Each migration's identifier and statements, oldest first.
    static let migrations: [(identifier: String, statements: [String])] = [
        ("v1", v1),
        ("v2", v2),
    ]

    /// Schema v1: custody, peers, messages, accepted conversations and our own profile.
    private static let v1 = [
        // Custody (`forward_store` in knit-next). `seq` orders rows by arrival: SQLite hands a new row a rowid above
        // every row it holds, and an INTEGER PRIMARY KEY survives a VACUUM, which renumbers a hidden rowid.
        """
        CREATE TABLE forward_store (
            seq INTEGER PRIMARY KEY,
            id BLOB NOT NULL UNIQUE,
            senderId BLOB NOT NULL,
            recipientId BLOB,
            groupId BLOB,
            type BLOB NOT NULL,
            isRoomChat INTEGER NOT NULL,
            origin INTEGER NOT NULL,
            signed BLOB NOT NULL,
            sig BLOB NOT NULL,
            sentAt INTEGER NOT NULL,
            receivedAt INTEGER NOT NULL,
            expiresAt INTEGER NOT NULL
        ) STRICT
        """,
        "CREATE INDEX forward_store_expiresAt ON forward_store (expiresAt)",
        // The pinned peers (`peers`).
        """
        CREATE TABLE peers (
            nodeId BLOB NOT NULL PRIMARY KEY,
            name BLOB NOT NULL,
            status BLOB NOT NULL,
            publicKey BLOB NOT NULL,
            deviceTag BLOB,
            protocolVersion INTEGER,
            capabilities INTEGER,
            updatedAt INTEGER NOT NULL,
            verified INTEGER NOT NULL,
            openToChat INTEGER NOT NULL
        ) STRICT
        """,
        // The message threads (`messages`). `seq` breaks ties in `sentAt` by the order rows were first stored, and an
        // upsert keeps it.
        """
        CREATE TABLE messages (
            seq INTEGER PRIMARY KEY,
            id BLOB NOT NULL UNIQUE,
            senderId BLOB NOT NULL,
            recipientId BLOB,
            conversationId BLOB NOT NULL,
            body BLOB NOT NULL,
            sentAt INTEGER NOT NULL,
            arrivedAt INTEGER,
            delivered INTEGER NOT NULL,
            pendingKey INTEGER NOT NULL
        ) STRICT
        """,
        "CREATE INDEX messages_conversationId_sentAt_seq ON messages (conversationId, sentAt, seq)",
        "CREATE INDEX messages_senderId_conversationId ON messages (senderId, conversationId)",
        "CREATE INDEX messages_pendingKey ON messages (recipientId, sentAt, seq) WHERE pendingKey = 1",
        // The threads the user accepted (`SettingsStore.acceptedConversations`).
        "CREATE TABLE accepted_conversations (conversationId BLOB NOT NULL PRIMARY KEY) STRICT",
        // Our own profile and its two clocks (`SettingsStore.profileVersion` and `profilePublishedAt`): one row.
        """
        CREATE TABLE own_profile (
            slot INTEGER PRIMARY KEY CHECK (slot = 0),
            name BLOB NOT NULL,
            status BLOB NOT NULL,
            openToChat INTEGER NOT NULL,
            version INTEGER NOT NULL,
            publishedAt INTEGER NOT NULL
        ) STRICT
        """,
    ]

    /// Schema v2: the signed profile each pin came from (`peer_profiles`, knit-next's database v16, its ADR
    /// 2026-09.g64k). It starts empty: a pin made before it gets its proof when that peer's profile next arrives.
    private static let v2 = [
        """
        CREATE TABLE peer_profiles (
            nodeId BLOB NOT NULL PRIMARY KEY,
            signed BLOB NOT NULL,
            sig BLOB NOT NULL,
            sentAt INTEGER NOT NULL
        ) STRICT
        """
    ]

    /// The migrator that brings any database this build knows up to date.
    ///
    /// A database a newer build migrated further opens as it is: every migration only adds, so this build reads
    /// the columns it knows and leaves the rest alone.
    static var migrator: DatabaseMigrator {
        var registered = DatabaseMigrator()
        for migration in migrations {
            registered.registerMigration(migration.identifier) { db in
                for statement in migration.statements {
                    try db.execute(sql: statement)
                }
            }
        }
        return registered
    }
}
