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
        ("v3", v3),
        ("v4", v4),
        ("v5", v5),
        ("v6", v6),
        ("v7", v7),
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

    /// Schema v3: groups (ADR 2026-09.n393). A message row gains its kind, so a group thread can hold status lines;
    /// every row already stored is an ordinary message. A group's members are rows of their own, in roster order, each
    /// with the leave and rejoin clocks that guard it (`groups` in knit-next's database, which keeps the clocks in
    /// status lines instead).
    private static let v3 = [
        "ALTER TABLE messages ADD COLUMN kind INTEGER NOT NULL DEFAULT 0",
        """
        CREATE TABLE groups (
            groupId BLOB NOT NULL PRIMARY KEY,
            name BLOB NOT NULL,
            createdBy BLOB NOT NULL,
            createdAt INTEGER NOT NULL,
            nameUpdatedAt INTEGER NOT NULL,
            hasLeft INTEGER NOT NULL,
            photoHash BLOB,
            photoUpdatedAt INTEGER
        ) STRICT
        """,
        """
        CREATE TABLE group_members (
            groupId BLOB NOT NULL,
            nodeId BLOB NOT NULL,
            position INTEGER NOT NULL,
            departed INTEGER NOT NULL,
            leftAt INTEGER,
            rejoinedAt INTEGER,
            PRIMARY KEY (groupId, nodeId)
        ) STRICT
        """,
    ]

    /// Schema v4: photos (ADR 2026-10.nh55). `blobs` indexes the blobs held, whose bytes live in files beside the
    /// database (``SQLBlobStore``). A peer gains the photo shown and the one its newest profile names, and our own
    /// profile gains its photo. Every row already stored has none.
    private static let v4 = [
        """
        CREATE TABLE blobs (
            hash BLOB NOT NULL PRIMARY KEY,
            mime BLOB NOT NULL,
            size INTEGER NOT NULL,
            storedAt INTEGER NOT NULL
        ) STRICT
        """,
        "ALTER TABLE peers ADD COLUMN avatarHash BLOB",
        "ALTER TABLE peers ADD COLUMN advertisedAvatarHash BLOB",
        "ALTER TABLE own_profile ADD COLUMN avatarHash BLOB",
    ]

    /// Schema v5: photos in chats (ADR 2026-10.nh55). A message gains what it carries: the blob's hash, its type, the
    /// key that opens a sealed one, and a file's name and size (`MessageEntity.attachment*`). Every row already stored
    /// carries nothing.
    private static let v5 = [
        "ALTER TABLE messages ADD COLUMN attachmentHash BLOB",
        "ALTER TABLE messages ADD COLUMN attachmentMime BLOB",
        "ALTER TABLE messages ADD COLUMN attachmentKey BLOB",
        "ALTER TABLE messages ADD COLUMN attachmentName BLOB",
        "ALTER TABLE messages ADD COLUMN attachmentSize INTEGER",
        "CREATE INDEX messages_attachmentHash ON messages (attachmentHash) WHERE attachmentHash IS NOT NULL",
    ]

    /// Schema v6: the people the user blocked (ADR 2026-10.5wgg), by node id, and the device tags their profiles carried
    /// (`SettingsStore.blockedNodeIds` and `blockedDeviceTags`). A database that predates it blocks nobody.
    private static let v6 = [
        "CREATE TABLE blocked_nodes (nodeId BLOB NOT NULL PRIMARY KEY) STRICT",
        "CREATE TABLE blocked_device_tags (deviceTag BLOB NOT NULL PRIMARY KEY) STRICT",
    ]

    /// Schema v7: what the content filter made of a message's words (ADR 2026-10.e4kz), knit-next's
    /// `MessageEntity.moderation` with one code of this port's own, 2 for a message not yet screened. Every row already
    /// stored reads 0, shown as it always was. The partial index keeps a launch's look for unscreened rows to those rows.
    private static let v7 = [
        "ALTER TABLE messages ADD COLUMN moderation INTEGER NOT NULL DEFAULT 0",
        "CREATE INDEX messages_waiting ON messages (seq) WHERE moderation = 2",
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
