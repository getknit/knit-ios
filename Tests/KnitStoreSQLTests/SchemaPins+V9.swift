// The schema each migration leaves is pinned in `SchemaPins`; v9's pin lives here so neither file outgrows the
// lint's limits.

extension SchemaPins {
    /// The schema after v9: v8's, and reactions. `reactions` sorts after every table v8 has, and v9 adds no index, so
    /// its entry follows v8's whole dump. Frozen once committed.
    static let v9 =
        v8 + """

            table reactions
            CREATE TABLE reactions (
                messageId BLOB NOT NULL,
                reactor BLOB NOT NULL,
                emoji BLOB,
                updatedAt INTEGER NOT NULL,
                PRIMARY KEY (messageId, reactor)
            ) STRICT;

            """
}
