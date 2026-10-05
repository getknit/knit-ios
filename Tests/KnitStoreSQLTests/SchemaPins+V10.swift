// The schema each migration leaves is pinned in `SchemaPins`; v10's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v10: v9's, and a photo's size on its message (ADR 2026-10.6cas). SQLite writes an added column
    /// into its table's statement, at the end, so only that line moves. Frozen once committed.
    static let v10 = v9.replacingOccurrences(
        of: "moderation INTEGER NOT NULL DEFAULT 0) STRICT;",
        with: "moderation INTEGER NOT NULL DEFAULT 0, attachmentWidth INTEGER, attachmentHeight INTEGER) STRICT;"
    )
}
