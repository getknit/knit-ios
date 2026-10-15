// The schema each migration leaves is pinned in `SchemaPins`; v16's pin lives here so neither file outgrows the
// lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after v16: v15's, a peer's ratchet prekey and that prekey's watermark, and the prekey our own profile
    /// carries. Frozen once committed.
    static let v16 =
        v15
        .replacingOccurrences(
            of: ", avatarHash BLOB) STRICT;",
            with: ", avatarHash BLOB, prekeyId INTEGER) STRICT;"
        )
        .replacingOccurrences(
            of: ", avatarHash BLOB, advertisedAvatarHash BLOB) STRICT;",
            with:
                ", avatarHash BLOB, advertisedAvatarHash BLOB, prekeyId INTEGER, prekeyPub BLOB, prekeySig BLOB, "
                + "prekeyProfileAt INTEGER NOT NULL DEFAULT 0) STRICT;"
        )
}
