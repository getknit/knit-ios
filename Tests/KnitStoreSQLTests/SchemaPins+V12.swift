// The schema each migration leaves is pinned in `SchemaPins`; v12's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v12: v11's, the names a photo goes by on this phone, and an index on its plaintext's (ADR
    /// 2026-10.f3mv). Frozen once committed.
    static let v12 = v11.replacingOccurrences(
        of: "attachmentHeight INTEGER, attachmentAnimated INTEGER) STRICT;",
        with: "attachmentHeight INTEGER, attachmentAnimated INTEGER, attachmentPlainHash BLOB, attachmentSourceHash BLOB) STRICT;"
    ).replacingOccurrences(
        of: """
            CREATE INDEX messages_attachmentHash ON messages (attachmentHash) WHERE attachmentHash IS NOT NULL;

            """,
        with: """
            CREATE INDEX messages_attachmentHash ON messages (attachmentHash) WHERE attachmentHash IS NOT NULL;

            index messages_attachmentPlainHash
            CREATE INDEX messages_attachmentPlainHash ON messages (attachmentPlainHash) WHERE attachmentPlainHash IS NOT NULL;

            """
    )
}
