// v24 lives here so the schema's enum stays inside the lint's length; like every migration it is frozen once committed.

extension Schema {
    /// Schema v24: our own presence keys (ADR 2026-11.prsp), knit-next's `own_presence_keys` with its mark columns
    /// (`OwnPresenceKeyEntity`, `data/presencekey/PresenceKeyEntities.kt:17-33` at `cad69c77b`): at most three generations,
    /// each with the key, when it was minted and activated (none while it is the next key), its audience as the sorted
    /// node ids comma-joined in a UTF-8 `BLOB` (``StoredText``; Android's `PresenceKeyAudience`), and the advertiser's
    /// high-water mark under it, none until it first airs. The generation is the row's key. `link_owed_resets` does not
    /// come with it: nothing here owes a reset over a link (a reinstall sends none). Nothing kept a key of ours before
    /// v24, so a database it migrates holds none.
    static let v24 = [
        """
        CREATE TABLE own_presence_keys (
            generation INTEGER PRIMARY KEY NOT NULL,
            key BLOB NOT NULL,
            mintedAt INTEGER NOT NULL,
            activatedAt INTEGER,
            audience BLOB NOT NULL,
            markSlot INTEGER,
            markRestart INTEGER
        ) STRICT
        """
    ]
}
