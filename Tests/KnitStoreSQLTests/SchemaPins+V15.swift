// The schema each migration leaves is pinned in `SchemaPins`; v15's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v15: v14's, and whether nobody has read a message, with the index of those nobody has. Frozen
    /// once committed.
    static let v15 =
        v14
        .replacingOccurrences(
            of: "mentions BLOB) STRICT;",
            with: "mentions BLOB, unread INTEGER NOT NULL DEFAULT 0) STRICT;"
        )
        .replacingOccurrences(
            of: "index messages_waiting\n",
            with: """
                index messages_unread
                CREATE INDEX messages_unread ON messages (conversationId) WHERE unread = 1;

                index messages_waiting

                """
        )
}
