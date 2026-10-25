// The schema each migration leaves is pinned in `SchemaPins`; v19's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v19: v18's, a JPEG's EXIF-less name and an index on it (ADR 2026-10.f3mv, #12). Frozen once
    /// committed.
    static let v19 =
        v18
        .replacingOccurrences(
            of: "mentions BLOB, unread INTEGER NOT NULL DEFAULT 0) STRICT;",
            with: "mentions BLOB, unread INTEGER NOT NULL DEFAULT 0, attachmentExiflessHash BLOB) STRICT;"
        )
        .replacingOccurrences(
            of: "index messages_attachmentHash\n",
            with: """
                index messages_attachmentExiflessHash
                CREATE INDEX messages_attachmentExiflessHash ON messages (attachmentExiflessHash) \
                WHERE attachmentExiflessHash IS NOT NULL;

                index messages_attachmentHash

                """
        )
}
