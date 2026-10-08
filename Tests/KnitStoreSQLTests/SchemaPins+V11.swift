// The schema each migration leaves is pinned in `SchemaPins`; v11's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v11: v10's, and whether a photo moves on its message (ADR 2026-10.6cas). SQLite writes an added
    /// column into its table's statement, at the end, so only that line moves. Frozen once committed.
    static let v11 = v10.replacingOccurrences(
        of: "attachmentWidth INTEGER, attachmentHeight INTEGER) STRICT;",
        with: "attachmentWidth INTEGER, attachmentHeight INTEGER, attachmentAnimated INTEGER) STRICT;"
    )
}
