// The schema each migration leaves is pinned in `SchemaPins`; v5's pin lives here so neither file outgrows the
// lint's limits.

extension SchemaPins {
    /// The schema after v5: what a message carries, a photo or a file (ADR 2026-10.nh55). Frozen once committed.
    static let v5 = """
        index forward_store_expiresAt
        CREATE INDEX forward_store_expiresAt ON forward_store (expiresAt);

        index messages_attachmentHash
        CREATE INDEX messages_attachmentHash ON messages (attachmentHash) WHERE attachmentHash IS NOT NULL;

        index messages_conversationId_sentAt_seq
        CREATE INDEX messages_conversationId_sentAt_seq ON messages (conversationId, sentAt, seq);

        index messages_pendingKey
        CREATE INDEX messages_pendingKey ON messages (recipientId, sentAt, seq) WHERE pendingKey = 1;

        index messages_senderId_conversationId
        CREATE INDEX messages_senderId_conversationId ON messages (senderId, conversationId);

        table accepted_conversations
        CREATE TABLE accepted_conversations (conversationId BLOB NOT NULL PRIMARY KEY) STRICT;

        table blobs
        CREATE TABLE blobs (
            hash BLOB NOT NULL PRIMARY KEY,
            mime BLOB NOT NULL,
            size INTEGER NOT NULL,
            storedAt INTEGER NOT NULL
        ) STRICT;

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

        table group_members
        CREATE TABLE group_members (
            groupId BLOB NOT NULL,
            nodeId BLOB NOT NULL,
            position INTEGER NOT NULL,
            departed INTEGER NOT NULL,
            leftAt INTEGER,
            rejoinedAt INTEGER,
            PRIMARY KEY (groupId, nodeId)
        ) STRICT;

        table groups
        CREATE TABLE groups (
            groupId BLOB NOT NULL PRIMARY KEY,
            name BLOB NOT NULL,
            createdBy BLOB NOT NULL,
            createdAt INTEGER NOT NULL,
            nameUpdatedAt INTEGER NOT NULL,
            hasLeft INTEGER NOT NULL,
            photoHash BLOB,
            photoUpdatedAt INTEGER
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
        , kind INTEGER NOT NULL DEFAULT 0, attachmentHash BLOB, attachmentMime BLOB, attachmentKey BLOB, \
        attachmentName BLOB, attachmentSize INTEGER) STRICT;

        table own_profile
        CREATE TABLE own_profile (
            slot INTEGER PRIMARY KEY CHECK (slot = 0),
            name BLOB NOT NULL,
            status BLOB NOT NULL,
            openToChat INTEGER NOT NULL,
            version INTEGER NOT NULL,
            publishedAt INTEGER NOT NULL
        , avatarHash BLOB) STRICT;

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
        , avatarHash BLOB, advertisedAvatarHash BLOB) STRICT;

        """
}
