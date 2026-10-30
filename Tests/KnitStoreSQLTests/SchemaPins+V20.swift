// The schema each migration leaves is pinned in `SchemaPins`; v20's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v20: v19's, a reply's quote check and its words' verdict, and an index on each (knit-next ADR
    /// 2026-10.gpa3). Frozen once committed.
    static let v20 =
        v19
        .replacingOccurrences(
            of: "attachmentExiflessHash BLOB) STRICT;",
            with: """
                attachmentExiflessHash BLOB, replyCheck INTEGER NOT NULL DEFAULT 0, \
                replyToFlagged INTEGER NOT NULL DEFAULT 0) STRICT;
                """
        )
        .replacingOccurrences(
            of: "index messages_senderId_conversationId\n",
            with: """
                index messages_quoteWaiting
                CREATE INDEX messages_quoteWaiting ON messages (seq) WHERE replyToFlagged = 2 AND replyCheck = 0;

                index messages_replyToId
                CREATE INDEX messages_replyToId ON messages (replyToId, replyCheck) WHERE replyToId IS NOT NULL;

                index messages_senderId_conversationId

                """
        )
}
