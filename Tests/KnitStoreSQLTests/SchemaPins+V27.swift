// The schema each migration leaves is pinned in `SchemaPins`; v27-peer-last-seen's pin lives here so neither file outgrows
// the lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after `v27-peer-last-seen`: v26's, and when each peer was last heard (knit-next ADR 2026-10.k8ge). Frozen
    /// once committed.
    static let v27PeerLastSeen =
        v26PrevRootOwnInit
        .replacingOccurrences(
            of: "prekeyProfileAt INTEGER NOT NULL DEFAULT 0) STRICT;",
            with: "prekeyProfileAt INTEGER NOT NULL DEFAULT 0, lastSeenAt INTEGER NOT NULL DEFAULT 0) STRICT;"
        )
}
