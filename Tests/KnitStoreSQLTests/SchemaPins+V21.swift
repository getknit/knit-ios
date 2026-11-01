// The schema each migration leaves is pinned in `SchemaPins`; v21's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v21: v20's, and the capabilities our own last profile carried (knit-ios #25). Frozen once
    /// committed.
    static let v21 =
        v20
        .replacingOccurrences(
            of: ", avatarHash BLOB, prekeyId INTEGER) STRICT;",
            with: ", avatarHash BLOB, prekeyId INTEGER, capabilities INTEGER) STRICT;"
        )
}
