import KnitWire

/// Our presence keys' last generation, kept beside the prekeys in the identity's own item (ADR 2026-11.prsp, "Where each
/// piece is stored"): Android's `presence_key_last_generation` setting, which its backup carries
/// (`PresenceKeyEngineStore.lastGeneration`, `mesh/PresenceKeyEngine.kt:683-687` at knit-next `cad69c77b`). Here the
/// database stays out of backups, and a reinstall keeps the Keychain and loses the database (ADR 2026-09.tkww), so the item
/// is the one place it survives both.
///
/// **The stored form grows additively,** as the prekeys and the answered inits did: `presenceLast`, an integer, a fifth key
/// of the identity's map, which an older build ignores and writes back as it was stored.
///
/// **A write** reads the item, checks the identity in it byte for byte, replaces `presenceLast` alone and keeps every other
/// entry (the prekeys and the answered inits byte for byte), writes and reads back, as ``PrekeyRing/rotate(now:)`` does.
/// A mint writes the generation here before the row that uses it, and a write that throws fails the mint. A read that
/// cannot answer throws, so a store before the first unlock is never taken for a last generation of 0. Every call is
/// serialized with the ring's other writes: the engine makes them on the `Mesh` actor, and knit-peer's node on its own.
extension PrekeyRing {
    private static let presenceLastKey = "presenceLast"

    /// The last generation a mint of ours took, 0 when none was ever recorded (`lastGeneration`). Throws when the store
    /// cannot answer, holds another identity, or keeps the value as anything but one integer.
    public func presenceLastGeneration() throws(Failure) -> Int64 {
        let lists = try Self.entries(read(), of: identity).filter { $0.key == .text(Self.presenceLastKey) }
        guard let entry = lists.first else {
            return 0
        }
        guard lists.count == 1, let value = entry.value.int64 else {
            throw .unreadablePresenceGeneration
        }
        return value
    }

    /// Records `generation` as the last a mint of ours took (`setLastGeneration`), beside every other entry of the item,
    /// and proves it reads back.
    public func setPresenceLastGeneration(_ generation: Int64) throws(Failure) {
        let entries = try Self.entries(read(), of: identity)
        try persist(CBOR(generation), as: Self.presenceLastKey, beside: entries)
    }

    /// Clamps a last generation more than `aheadMilliseconds` past `now` to `now`, and answers the clamped value, or `nil`
    /// when nothing changed (`clampRestored`, `PresenceKeyPolicy.kt:171-177`): a value left by a clock that ran far ahead.
    /// Called only where a reinstall is found, never at every start: every session starts again there, so the lower
    /// generations that follow are a new era to every receiver, while a clamp inside a living root would hand a peer a
    /// lower generation under the same root, which it refuses as older.
    public func clampPresenceLastGeneration(now: Int64, aheadMilliseconds: Int64) throws(Failure) -> Int64? {
        let last = try presenceLastGeneration()
        let (bound, overflow) = now.addingReportingOverflow(aheadMilliseconds)
        guard last > (overflow ? Int64.max : bound) else {
            return nil
        }
        try setPresenceLastGeneration(now)
        return now
    }
}
