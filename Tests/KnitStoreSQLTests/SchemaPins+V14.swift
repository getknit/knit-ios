// The schema each migration leaves is pinned in `SchemaPins`; v14's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v14: v13's, and the people a message mentions. Frozen once committed.
    static let v14 = v13.replacingOccurrences(
        of: "replyToHasAttachment INTEGER NOT NULL DEFAULT 0) STRICT;",
        with: "replyToHasAttachment INTEGER NOT NULL DEFAULT 0, mentions BLOB) STRICT;"
    )
}
