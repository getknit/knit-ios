// The schema each migration leaves is pinned in `SchemaPins`; v13's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v13: v12's, and the quote a reply carries (ADR 2026-10.mn29). Frozen once committed.
    static let v13 = v12.replacingOccurrences(
        of: "attachmentPlainHash BLOB, attachmentSourceHash BLOB) STRICT;",
        with: """
            attachmentPlainHash BLOB, attachmentSourceHash BLOB, replyToId BLOB, replyToAuthorId BLOB, replyToAuthor BLOB, \
            replyToSnippet BLOB, replyToHasAttachment INTEGER NOT NULL DEFAULT 0) STRICT;
            """
    )
}
