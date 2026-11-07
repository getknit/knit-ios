// The schema each migration leaves is pinned in `SchemaPins`; v22's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v22: v21's, and the presence keys peers handed us (ADR 2026-11.sv5t). Frozen once committed.
    static let v22 =
        v21
        .replacingOccurrences(of: "table peer_profiles\n", with: presenceKeys + "table peer_profiles\n")

    private static let presenceKeys = """
        table peer_presence_keys
        CREATE TABLE peer_presence_keys (
            nodeId BLOB NOT NULL,
            generation INTEGER NOT NULL,
            key BLOB NOT NULL,
            receivedAt INTEGER NOT NULL,
            rootTag INTEGER NOT NULL,
            PRIMARY KEY (nodeId, generation)
        ) STRICT;


        """
}
