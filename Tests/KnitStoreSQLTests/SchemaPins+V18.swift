// The schema each migration leaves is pinned in `SchemaPins`; v18's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v18: v17's, and the group form's four tables with their indexes. Frozen once committed.
    static let v18 =
        v17
        .replacingOccurrences(
            of: "index messages_attachmentHash\n",
            with: """
                index group_recv_chains_lastUsedAt
                CREATE INDEX group_recv_chains_lastUsedAt ON group_recv_chains (lastUsedAt);

                index group_send_chains_mintedAt
                CREATE INDEX group_send_chains_mintedAt ON group_send_chains (mintedAt);

                index group_skipped_keys_createdAt
                CREATE INDEX group_skipped_keys_createdAt ON group_skipped_keys (createdAt);

                index messages_attachmentHash

                """
        )
        .replacingOccurrences(of: "table group_members\n", with: keySends + "table group_members\n")
        .replacingOccurrences(of: "table groups\n", with: groupChains + "table groups\n")

    private static let keySends = """
        table group_key_sends
        CREATE TABLE group_key_sends (
            groupId BLOB NOT NULL,
            memberId BLOB NOT NULL,
            sentEpoch INTEGER NOT NULL,
            sentAt INTEGER NOT NULL,
            ackedEpoch INTEGER NOT NULL,
            ackedAt INTEGER NOT NULL,
            PRIMARY KEY (groupId, memberId)
        ) STRICT;


        """

    private static let groupChains = """
        table group_recv_chains
        CREATE TABLE group_recv_chains (
            groupId BLOB NOT NULL,
            senderId BLOB NOT NULL,
            epoch INTEGER NOT NULL,
            mintedAt INTEGER NOT NULL,
            chainKey BLOB NOT NULL,
            next INTEGER NOT NULL,
            lastUsedAt INTEGER NOT NULL,
            PRIMARY KEY (groupId, senderId, epoch, mintedAt)
        ) STRICT;

        table group_send_chains
        CREATE TABLE group_send_chains (
            groupId BLOB NOT NULL,
            epoch INTEGER NOT NULL,
            seed BLOB NOT NULL,
            chainKey BLOB NOT NULL,
            count INTEGER NOT NULL,
            mintedAt INTEGER NOT NULL,
            PRIMARY KEY (groupId, epoch)
        ) STRICT;

        table group_skipped_keys
        CREATE TABLE group_skipped_keys (
            groupId BLOB NOT NULL,
            senderId BLOB NOT NULL,
            epoch INTEGER NOT NULL,
            mintedAt INTEGER NOT NULL,
            idx INTEGER NOT NULL,
            msgKey BLOB NOT NULL,
            createdAt INTEGER NOT NULL,
            PRIMARY KEY (groupId, senderId, epoch, mintedAt, idx)
        ) STRICT;


        """
}
