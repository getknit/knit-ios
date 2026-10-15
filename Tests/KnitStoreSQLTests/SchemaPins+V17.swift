// The schema each migration leaves is pinned in `SchemaPins`; v17's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v17: v16's, and the DM ratchet's four tables with their indexes. Frozen once committed.
    static let v17 =
        v16
        .replacingOccurrences(
            of: "table accepted_conversations\n",
            with: """
                index ratchet_local_epochs_createdAt
                CREATE INDEX ratchet_local_epochs_createdAt ON ratchet_local_epochs (createdAt);

                index ratchet_recv_epochs_lastUsedAt
                CREATE INDEX ratchet_recv_epochs_lastUsedAt ON ratchet_recv_epochs (lastUsedAt);

                index ratchet_skipped_keys_createdAt
                CREATE INDEX ratchet_skipped_keys_createdAt ON ratchet_skipped_keys (createdAt);

                table accepted_conversations

                """
        )
        .replacingOccurrences(of: "table reactions\n", with: ratchetTables + "table reactions\n")

    private static let ratchetTables = """
        table ratchet_local_epochs
        CREATE TABLE ratchet_local_epochs (
            peerId BLOB NOT NULL,
            epoch INTEGER NOT NULL,
            priv BLOB NOT NULL,
            pub BLOB NOT NULL,
            createdAt INTEGER NOT NULL,
            PRIMARY KEY (peerId, epoch)
        ) STRICT;

        table ratchet_recv_epochs
        CREATE TABLE ratchet_recv_epochs (
            peerId BLOB NOT NULL,
            epoch INTEGER NOT NULL,
            rootTag INTEGER NOT NULL,
            chainKey BLOB NOT NULL,
            next INTEGER NOT NULL,
            lastUsedAt INTEGER NOT NULL,
            PRIMARY KEY (peerId, epoch, rootTag)
        ) STRICT;

        table ratchet_sessions
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
        ) STRICT;

        table ratchet_skipped_keys
        CREATE TABLE ratchet_skipped_keys (
            peerId BLOB NOT NULL,
            epoch INTEGER NOT NULL,
            idx INTEGER NOT NULL,
            rootTag INTEGER NOT NULL,
            msgKey BLOB NOT NULL,
            createdAt INTEGER NOT NULL,
            PRIMARY KEY (peerId, epoch, idx, rootTag)
        ) STRICT;


        """
}
