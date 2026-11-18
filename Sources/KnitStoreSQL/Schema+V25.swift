// v25-own-profile-frame lives here so the schema's enum stays inside the lint's length; like every migration it is
// frozen once committed.

extension Schema {
    /// Schema `v25-own-profile-frame`: the profile frame we published under our current stamp, its signature and signed
    /// bytes kept byte for byte outside custody, whose quotas evict our own frames like anyone's (ADR 2026-11.xfcq, after
    /// knit-next ADR 2026-11.khhj and its `own_profile_frame_sig` and `own_profile_frame_signed` settings keys). A table of
    /// its own, not columns on `own_profile`: `SQLOwnProfileStore.save` replaces that row whole, and would null them. One
    /// row, as `own_profile` holds one. Named, not numbered: GRDB keys a migration by its identifier, and a phone that ran
    /// this one under a bare `v25` would skip another branch's `v25`. A database it migrates keeps its profile and keeps no
    /// frame, so its first start takes custody's row as the kept frame, or signs once when the row is gone.
    static let v25OwnProfileFrame = [
        """
        CREATE TABLE own_profile_frame (
            slot INTEGER PRIMARY KEY CHECK (slot = 0),
            sig BLOB NOT NULL,
            signed BLOB NOT NULL
        ) STRICT
        """
    ]
}
