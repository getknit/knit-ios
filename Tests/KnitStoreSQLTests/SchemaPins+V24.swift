// The schema each migration leaves is pinned in `SchemaPins`; v24's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v24: v23's, and our own presence keys (ADR 2026-11.prsp). Frozen once committed.
    static let v24 =
        v23
        .replacingOccurrences(of: "table own_profile\n", with: ownPresenceKeys + "table own_profile\n")

    private static let ownPresenceKeys = """
        table own_presence_keys
        CREATE TABLE own_presence_keys (
            generation INTEGER PRIMARY KEY NOT NULL,
            key BLOB NOT NULL,
            mintedAt INTEGER NOT NULL,
            activatedAt INTEGER,
            audience BLOB NOT NULL,
            markSlot INTEGER,
            markRestart INTEGER
        ) STRICT;


        """
}
