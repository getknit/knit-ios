// v17 lives here so the schema's enum stays inside the lint's length; like every migration it is frozen once committed.

extension Schema {
    /// Schema v17: the DM ratchet's sessions (ADR 2026-10.5sk9), knit-next's four `ratchet_*` tables as its database v21
    /// left them (`data/ratchet/RatchetEntities.kt`, `KnitMigrations.kt`): one session per peer, our own epoch pairs, the
    /// peer's receive chains and the skipped keys, with Android's indexes. The last two carry the root tag at the end of
    /// their keys, so the lookup by `(peer, epoch)` still runs on the key (knit-next ADR 2026-10.gcrd). The session leaves
    /// out `sendEpochExport`, the spool's, and `updatedAt`, which nothing reads. Nothing was stored before v17, so a
    /// database it migrates holds no session.
    static let v17 = [
        """
        CREATE TABLE ratchet_sessions (
            peerId BLOB NOT NULL PRIMARY KEY,
            confirmed INTEGER NOT NULL,
            weAreInitiator INTEGER NOT NULL,
            root BLOB NOT NULL,
            prevRoot BLOB,
            prevRootWeAreInitiator INTEGER NOT NULL,
            prevRootExpiresAt INTEGER NOT NULL,
            establishedAt INTEGER NOT NULL,
            initEphPub BLOB,
            initPkid INTEGER NOT NULL,
            peerInitEphPub BLOB,
            peerBasePub BLOB,
            peerBaseEpoch INTEGER NOT NULL,
            sendEpoch INTEGER NOT NULL,
            sendEpochPub BLOB,
            sendChainKey BLOB,
            sendCount INTEGER NOT NULL,
            sendEpochStartedAt INTEGER NOT NULL,
            sendEpochBaseEpoch INTEGER NOT NULL,
            highestPeAcked INTEGER NOT NULL,
            lastResetSentAt INTEGER NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE ratchet_local_epochs (
            peerId BLOB NOT NULL,
            epoch INTEGER NOT NULL,
            priv BLOB NOT NULL,
            pub BLOB NOT NULL,
            createdAt INTEGER NOT NULL,
            PRIMARY KEY (peerId, epoch)
        ) STRICT
        """,
        "CREATE INDEX ratchet_local_epochs_createdAt ON ratchet_local_epochs (createdAt)",
        """
        CREATE TABLE ratchet_recv_epochs (
            peerId BLOB NOT NULL,
            epoch INTEGER NOT NULL,
            rootTag INTEGER NOT NULL,
            chainKey BLOB NOT NULL,
            next INTEGER NOT NULL,
            lastUsedAt INTEGER NOT NULL,
            PRIMARY KEY (peerId, epoch, rootTag)
        ) STRICT
        """,
        "CREATE INDEX ratchet_recv_epochs_lastUsedAt ON ratchet_recv_epochs (lastUsedAt)",
        """
        CREATE TABLE ratchet_skipped_keys (
            peerId BLOB NOT NULL,
            epoch INTEGER NOT NULL,
            idx INTEGER NOT NULL,
            rootTag INTEGER NOT NULL,
            msgKey BLOB NOT NULL,
            createdAt INTEGER NOT NULL,
            PRIMARY KEY (peerId, epoch, idx, rootTag)
        ) STRICT
        """,
        "CREATE INDEX ratchet_skipped_keys_createdAt ON ratchet_skipped_keys (createdAt)",
    ]
}
