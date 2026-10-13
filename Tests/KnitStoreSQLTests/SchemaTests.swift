import Foundation
import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

/// The schema is append-only, and each migration leaves exactly the schema pinned here (ADR 2026-09.nyya).
///
/// To change the schema, add a migration at the end of ``Schema/migrations``, pin what it leaves in
/// ``SchemaPins/after``, and add a test that migrates rows written under the previous one. Never edit a pin that
/// is already here: a phone that ran that migration keeps the schema it left.
@Suite struct SchemaTests {
    /// The migrations every earlier build has run, in order.
    private static let frozen = ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13"]

    @Test func migrationsOnlyEverGrowAtTheEnd() {
        let identifiers = Schema.migrations.map(\.identifier)
        #expect(Array(identifiers.prefix(Self.frozen.count)) == Self.frozen)
        #expect(Set(identifiers).count == identifiers.count, "an identifier names one migration")
        #expect(KnitDatabase.schemaVersion == identifiers.count)
    }

    @Test func everyMigrationLeavesItsPinnedSchema() throws {
        #expect(Schema.migrations.map(\.identifier) == SchemaPins.after.map(\.identifier), "every migration has a pin")
        for (identifier, pinned) in SchemaPins.after {
            let queue = try DatabaseQueue()
            try Schema.migrator.migrate(queue, upTo: identifier)
            let schema = try SchemaPins.dump(queue)
            #expect(schema == pinned, "the schema after \(identifier)")
        }
    }

    @Test func aFreshDatabaseHasTheNewestSchema() throws {
        let database = try KnitDatabase.inMemory(failures: recordFailure)
        let schema = try SchemaPins.dump(database.writer)
        #expect(schema == SchemaPins.after.last?.schema)
    }

    @Test func everyTableIsStrict() throws {
        let database = try KnitDatabase.inMemory(failures: recordFailure)
        let tables = try database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT name, strict FROM pragma_table_list
                    WHERE schema = 'main' AND type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                    ORDER BY name
                    """
            ).map { (name: $0["name"] as String, strict: $0["strict"] as Bool) }
        }
        #expect(
            tables.map(\.name) == [
                "accepted_conversations", "blobs", "blocked_device_tags", "blocked_nodes", "deleted_messages", "forward_store",
                "group_members", "groups",
                "messages", "own_profile",
                "peer_profiles", "peers", "reactions",
            ])
        let loose = tables.filter { !$0.strict }.map(\.name)
        #expect(loose.isEmpty, "not STRICT: \(loose)")
    }

    @Test func v2KeepsEveryPinAndStartsItsProofsEmpty() throws {
        // A pin made under v1 gets its proof of key when that peer's profile next arrives (knit-next ADR 2026-09.g64k).
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v1")
        let bob = fixtureNodeId(2)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO peers (nodeId, name, status, publicKey, updatedAt, verified, openToChat)
                    VALUES (?, ?, ?, ?, 7, 1, 0)
                    """,
                arguments: [StoredText.bytes(bob.string), StoredText.bytes("Bob"), StoredText.bytes(""), StoredText.bytes("key")]
            )
        }
        let database = try KnitDatabase(writer: queue, failures: recordFailure)
        let peers = SQLPeerStore(database)
        #expect(peers.peer(bob)?.name == "Bob")
        #expect(peers.peer(bob)?.verified == true)
        #expect(peers.profileFrame(of: bob) == nil)
    }

    @Test func v3KeepsEveryMessageAsAnOrdinaryOneAndStartsWithNoGroups() throws {
        // Every row stored before groups is a message, not a status line (ADR 2026-09.n393).
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v2")
        let bob = fixtureNodeId(2)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (id, senderId, conversationId, body, sentAt, delivered, pendingKey)
                    VALUES (?, ?, ?, ?, 3, 0, 0)
                    """,
                arguments: [StoredText.bytes("m1"), StoredText.bytes(bob.string), StoredText.bytes("nearby"), StoredText.bytes("hi")]
            )
        }
        let database = try KnitDatabase(writer: queue, failures: recordFailure)
        let messages = SQLMessageStore(database)
        #expect(messages.message("m1")?.kind == .message)
        #expect(messages.threadHeads().map(\.id) == ["m1"])
        #expect(SQLGroupStore(database).groups().isEmpty)
    }

    @Test func v4KeepsEveryPeerAndOurProfileWithNoPhotoAndHoldsNoBlobs() throws {
        // Nobody had a photo before v4 (ADR 2026-10.nh55).
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v3")
        let bob = fixtureNodeId(2)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO peers (nodeId, name, status, publicKey, updatedAt, verified, openToChat)
                    VALUES (?, ?, ?, ?, 7, 0, 1)
                    """,
                arguments: [StoredText.bytes(bob.string), StoredText.bytes("Bob"), StoredText.bytes(""), StoredText.bytes("key")]
            )
            try db.execute(
                sql: "INSERT INTO own_profile (slot, name, status, openToChat, version, publishedAt) VALUES (0, ?, ?, 0, 5, 6)",
                arguments: [StoredText.bytes("Me"), StoredText.bytes("")]
            )
        }
        let database = try KnitDatabase(writer: queue, failures: recordFailure)
        let peer = SQLPeerStore(database).peer(bob)
        #expect(peer?.name == "Bob" && peer?.openToChat == true)
        #expect(peer?.avatarHash == nil && peer?.advertisedAvatarHash == nil)
        let own = SQLOwnProfileStore(database).load()
        #expect(own == OwnProfile(name: "Me", version: 5, publishedAt: 6))
        let blobs = try database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM blobs") }
        #expect(blobs == 0)
    }

    @Test func v5KeepsEveryMessageCarryingNothing() throws {
        // No message carried a photo before v5 (ADR 2026-10.nh55).
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v4")
        let bob = fixtureNodeId(2)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (id, senderId, conversationId, body, sentAt, delivered, pendingKey, kind)
                    VALUES (?, ?, ?, ?, 3, 0, 0, 0)
                    """,
                arguments: [StoredText.bytes("m1"), StoredText.bytes(bob.string), StoredText.bytes("nearby"), StoredText.bytes("hi")]
            )
        }
        let database = try KnitDatabase(writer: queue, failures: recordFailure)
        let messages = SQLMessageStore(database)
        #expect(messages.message("m1")?.body == "hi")
        #expect(messages.message("m1")?.attachment == nil)
        #expect(messages.attachmentHashes().isEmpty)
    }

    @Test func v6BlocksNobody() throws {
        // Nobody was blocked before v6 (ADR 2026-10.5wgg), and every thread keeps its head.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v5")
        let bob = fixtureNodeId(2)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (id, senderId, conversationId, body, sentAt, delivered, pendingKey, kind)
                    VALUES (?, ?, ?, ?, 3, 0, 0, 0)
                    """,
                arguments: [StoredText.bytes("m1"), StoredText.bytes(bob.string), StoredText.bytes("nearby"), StoredText.bytes("hi")]
            )
        }
        let database = try KnitDatabase(writer: queue, failures: recordFailure)
        let blocks = SQLBlockStore(database)
        #expect(blocks.blockedNodeIds().isEmpty)
        #expect(!blocks.isBlocked(deviceTag: "0011223344556677"))
        #expect(SQLMessageStore(database).threadHeads(excludingSenders: blocks.blockedNodeIds()).map(\.id) == ["m1"])
    }

    @Test func grdbCutsABoundStringAtItsFirstNul() throws {
        // Why every string is a BLOB (StoredText). If GRDB ever binds a String's whole length, TEXT columns become
        // possible, though v1 stays as it is.
        let length = try DatabaseQueue().read { db in
            try Int.fetchOne(db, sql: "SELECT length(CAST(? AS BLOB))", arguments: ["a\u{0}b"])
        }
        #expect(length == 1)
        #expect(StoredText.bytes("a\u{0}b") == Data([0x61, 0, 0x62]))
    }

    @Test func aStringBoundAsTextIsRefusedRatherThanStoredAsOtherBytes() throws {
        // GRDB binds a String NUL-terminated. A strict BLOB column refuses TEXT, so a store that forgot StoredText
        // fails in every test instead of keying rows by the wrong bytes.
        let database = try KnitDatabase.inMemory(failures: recordFailure)
        #expect(throws: DatabaseError.self) {
            try database.writer.write { db in
                try db.execute(sql: "INSERT INTO accepted_conversations (conversationId) VALUES (?)", arguments: ["nearby"])
            }
        }
    }
}

/// The schema each migration leaves, as `sqlite_master` spells it.
enum SchemaPins {
    /// Each migration's identifier and the schema a database has after it, oldest first. Frozen once committed.
    static let after: [(identifier: String, schema: String)] = [
        ("v1", v1),
        ("v2", v2),
        ("v3", v3),
        ("v4", v4),
        ("v5", v5),
        ("v6", v6),
        ("v7", v7),
        ("v8", v8),
        ("v9", v9),
        ("v10", v10),
        ("v11", v11),
        ("v12", v12),
        ("v13", v13),
    ]

    /// Every table, index and trigger this app made, sorted, with the statement SQLite keeps for it. GRDB's own
    /// bookkeeping and SQLite's automatic indexes are left out.
    static func dump(_ reader: any DatabaseReader) throws -> String {
        try reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT type, name, sql FROM sqlite_master
                    WHERE name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                    ORDER BY type, name
                    """
            ).map { "\($0["type"] as String) \($0["name"] as String)\n\($0["sql"] as String);\n" }.joined(separator: "\n")
        }
    }

    private static let v1 = """
        index forward_store_expiresAt
        CREATE INDEX forward_store_expiresAt ON forward_store (expiresAt);

        index messages_conversationId_sentAt_seq
        CREATE INDEX messages_conversationId_sentAt_seq ON messages (conversationId, sentAt, seq);

        index messages_pendingKey
        CREATE INDEX messages_pendingKey ON messages (recipientId, sentAt, seq) WHERE pendingKey = 1;

        index messages_senderId_conversationId
        CREATE INDEX messages_senderId_conversationId ON messages (senderId, conversationId);

        table accepted_conversations
        CREATE TABLE accepted_conversations (conversationId BLOB NOT NULL PRIMARY KEY) STRICT;

        table forward_store
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
        ) STRICT;

        table messages
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
        ) STRICT;

        table own_profile
        CREATE TABLE own_profile (
            slot INTEGER PRIMARY KEY CHECK (slot = 0),
            name BLOB NOT NULL,
            status BLOB NOT NULL,
            openToChat INTEGER NOT NULL,
            version INTEGER NOT NULL,
            publishedAt INTEGER NOT NULL
        ) STRICT;

        table peers
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
        ) STRICT;

        """

    private static let v2 = """
        index forward_store_expiresAt
        CREATE INDEX forward_store_expiresAt ON forward_store (expiresAt);

        index messages_conversationId_sentAt_seq
        CREATE INDEX messages_conversationId_sentAt_seq ON messages (conversationId, sentAt, seq);

        index messages_pendingKey
        CREATE INDEX messages_pendingKey ON messages (recipientId, sentAt, seq) WHERE pendingKey = 1;

        index messages_senderId_conversationId
        CREATE INDEX messages_senderId_conversationId ON messages (senderId, conversationId);

        table accepted_conversations
        CREATE TABLE accepted_conversations (conversationId BLOB NOT NULL PRIMARY KEY) STRICT;

        table forward_store
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
        ) STRICT;

        table messages
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
        ) STRICT;

        table own_profile
        CREATE TABLE own_profile (
            slot INTEGER PRIMARY KEY CHECK (slot = 0),
            name BLOB NOT NULL,
            status BLOB NOT NULL,
            openToChat INTEGER NOT NULL,
            version INTEGER NOT NULL,
            publishedAt INTEGER NOT NULL
        ) STRICT;

        table peer_profiles
        CREATE TABLE peer_profiles (
            nodeId BLOB NOT NULL PRIMARY KEY,
            signed BLOB NOT NULL,
            sig BLOB NOT NULL,
            sentAt INTEGER NOT NULL
        ) STRICT;

        table peers
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
        ) STRICT;

        """
}
