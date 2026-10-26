// The schema each migration leaves is pinned in `SchemaPins`; v23's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v23: v22's, and a voice note's length and waveform on its message (knit-next ADR 034). SQLite
    /// writes an added column into its table's statement, at the end, so only that line moves. Frozen once committed.
    static let v23 = v22.replacingOccurrences(
        of: "replyToFlagged INTEGER NOT NULL DEFAULT 0) STRICT;",
        with: "replyToFlagged INTEGER NOT NULL DEFAULT 0, voiceDurationMs INTEGER, voicePeaks BLOB) STRICT;"
    )
}
