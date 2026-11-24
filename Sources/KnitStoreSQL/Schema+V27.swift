// v27-peer-last-seen lives here so the schema's enum stays inside the lint's length; like every migration it is frozen
// once committed.

extension Schema {
    /// Schema `v27-peer-last-seen`: `peers.lastSeenAt`, when a signed frame of the peer's last reached us, so a stranger
    /// quiet for a week stops adding an alias to a contact's label (knit-next ADR 2026-10.k8ge, its `MIGRATION_18_19`,
    /// `KnitMigrations.kt:452-470` at `2e91518e3`). Seeded as Android seeds it, from the newest stamp the row already
    /// implies: its profile's watermark, or the publish stamp of the signed profile kept as its proof of key
    /// (`peer_profiles.sentAt`), whichever is later. Floored at 0, where Android's seed is not: both stamps are the peer's,
    /// and a negative one would only widen what the bank must subtract. A seed that runs early only makes a stranger yield
    /// sooner, and a contact never reads the column. Presentation only, as ``PeerRecord/lastSeenAt`` says. Named, not
    /// numbered: GRDB keys a migration by its identifier, and a phone that ran this one under a bare `v27` would skip
    /// another branch's `v27`.
    static let v27PeerLastSeen = [
        "ALTER TABLE peers ADD COLUMN lastSeenAt INTEGER NOT NULL DEFAULT 0",
        """
        UPDATE peers SET lastSeenAt = MAX(0, updatedAt,
            COALESCE((SELECT sentAt FROM peer_profiles WHERE peer_profiles.nodeId = peers.nodeId), 0))
        """,
    ]
}
