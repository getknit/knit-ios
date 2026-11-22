// The schema each migration leaves is pinned in `SchemaPins`; v26-prev-root-own-init's pin lives here so neither file
// outgrows the lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after `v26-prev-root-own-init`: v25's, and the stamp of our own init a race loser keeps draining (knit-next
    /// ADR 2026-10.4mjm; ADR 2026-10.5sk9's P9a amendment). Frozen once committed.
    static let v26PrevRootOwnInit =
        v25OwnProfileFrame
        .replacingOccurrences(
            of: "    lastResetSentAt INTEGER NOT NULL\n) STRICT;",
            with: "    lastResetSentAt INTEGER NOT NULL\n, prevRootOwnInitAt INTEGER) STRICT;"
        )
}
