// v18 lives here so the schema's enum stays inside the lint's length; like every migration it is frozen once committed.

extension Schema {
    /// Schema v18: the group form's state (ADR 2026-10.5sk9), knit-next's four group tables as its database v23 has them
    /// (`data/ratchet/GroupRatchetEntities.kt`, at `cbf2a487`): our send chains per group, each sender's receive chains
    /// and skipped keys, keyed by the mint as well as the epoch, and the seed outbox, with Android's indexes. Every id is a
    /// UTF-8 `BLOB`. The send chain leaves out `export`, the spool's, and `updatedAt`, which nothing reads, as v17's
    /// session does; a retired chain keeps its empty seed and chain key as empty blobs. Nothing was stored before v18, so
    /// a database it migrates holds no group state.
    static let v18 = [
        """
        CREATE TABLE group_send_chains (
            groupId BLOB NOT NULL,
            epoch INTEGER NOT NULL,
            seed BLOB NOT NULL,
            chainKey BLOB NOT NULL,
            count INTEGER NOT NULL,
            mintedAt INTEGER NOT NULL,
            PRIMARY KEY (groupId, epoch)
        ) STRICT
        """,
        "CREATE INDEX group_send_chains_mintedAt ON group_send_chains (mintedAt)",
        """
        CREATE TABLE group_recv_chains (
            groupId BLOB NOT NULL,
            senderId BLOB NOT NULL,
            epoch INTEGER NOT NULL,
            mintedAt INTEGER NOT NULL,
            chainKey BLOB NOT NULL,
            next INTEGER NOT NULL,
            lastUsedAt INTEGER NOT NULL,
            PRIMARY KEY (groupId, senderId, epoch, mintedAt)
        ) STRICT
        """,
        "CREATE INDEX group_recv_chains_lastUsedAt ON group_recv_chains (lastUsedAt)",
        """
        CREATE TABLE group_skipped_keys (
            groupId BLOB NOT NULL,
            senderId BLOB NOT NULL,
            epoch INTEGER NOT NULL,
            mintedAt INTEGER NOT NULL,
            idx INTEGER NOT NULL,
            msgKey BLOB NOT NULL,
            createdAt INTEGER NOT NULL,
            PRIMARY KEY (groupId, senderId, epoch, mintedAt, idx)
        ) STRICT
        """,
        "CREATE INDEX group_skipped_keys_createdAt ON group_skipped_keys (createdAt)",
        """
        CREATE TABLE group_key_sends (
            groupId BLOB NOT NULL,
            memberId BLOB NOT NULL,
            sentEpoch INTEGER NOT NULL,
            sentAt INTEGER NOT NULL,
            ackedEpoch INTEGER NOT NULL,
            ackedAt INTEGER NOT NULL,
            PRIMARY KEY (groupId, memberId)
        ) STRICT
        """,
    ]
}
