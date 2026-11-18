// The schema each migration leaves is pinned in `SchemaPins`; v25-own-profile-frame's pin lives here so neither file
// outgrows the lint's limits.

import Foundation

extension SchemaPins {
    /// The schema after `v25-own-profile-frame`: v24's, and the frame our profile was published as (ADR 2026-11.xfcq). The
    /// dump sorts by name, so the table follows `own_profile` and comes before `peer_presence_keys`. Frozen once committed.
    static let v25OwnProfileFrame =
        v24
        .replacingOccurrences(of: "table peer_presence_keys\n", with: ownProfileFrame + "table peer_presence_keys\n")

    private static let ownProfileFrame = """
        table own_profile_frame
        CREATE TABLE own_profile_frame (
            slot INTEGER PRIMARY KEY CHECK (slot = 0),
            sig BLOB NOT NULL,
            signed BLOB NOT NULL
        ) STRICT;


        """
}
