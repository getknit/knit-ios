// v22 lives here so the schema's enum stays inside the lint's length; like every migration it is frozen once committed.

extension Schema {
    /// Schema v22: the presence keys peers handed us over ctl 11 (knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t), knit-next's
    /// `peer_presence_keys` as its database v32 has it (`MIGRATION_31_32`, `data/KnitMigrations.kt:740-764` at `cad69c77b`):
    /// at most three generations per peer, each with the root tag its frame opened under, every column `NOT NULL` as
    /// Android's are, and the peer's id a UTF-8 `BLOB` (``StoredText``). Receive only, so neither `own_presence_keys` nor
    /// `link_owed_resets` comes with it. Nothing held a presence key before v22, so a database it migrates holds none.
    static let v22 = [
        """
        CREATE TABLE peer_presence_keys (
            nodeId BLOB NOT NULL,
            generation INTEGER NOT NULL,
            key BLOB NOT NULL,
            receivedAt INTEGER NOT NULL,
            rootTag INTEGER NOT NULL,
            PRIMARY KEY (nodeId, generation)
        ) STRICT
        """
    ]
}
