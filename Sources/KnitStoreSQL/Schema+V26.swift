// v26-prev-root-own-init lives here so the schema's enum stays inside the lint's length; like every migration it is
// frozen once committed.

extension Schema {
    /// Schema `v26-prev-root-own-init`: `ratchet_sessions.prevRootOwnInitAt`, set while a session's `prevRoot` is our own
    /// init, abandoned unconfirmed on a race we lost, to that init's own `establishedAt` (knit-next ADR 2026-10.4mjm, its
    /// `MIGRATION_28_29`, `KnitMigrations.kt:697-708` at `f018bc8ce`; ADR 2026-10.5sk9's P9a amendment). Null on every row a
    /// database it migrates holds: no build before it recorded the stamp, so a session that lost its race before the update
    /// never reclaims, as before. Local only, as the rest of the table. Named, not numbered: GRDB keys a migration by its
    /// identifier, and a phone that ran this one under a bare `v26` would skip another branch's `v26`.
    static let v26PrevRootOwnInit = [
        "ALTER TABLE ratchet_sessions ADD COLUMN prevRootOwnInitAt INTEGER"
    ]
}
