public import KnitWire

/// What a sealed tick needs from the engine, which ``AckSync`` asks and never answers itself: whether an author could read
/// one, and the two seals (the `canSeal`, `sealTick` and `originateTick` lambdas `MeshManager` hands knit-next's `AckSync`,
/// `MeshManager.kt:380-382` at `cbf2a487`). The ledger holds no key, so it stays free of crypto.
///
/// Phase P5d of the ratchet's port fills them (ADR 2026-10.5sk9). Until then the engine's are ``NoTickSealing``'s, so every
/// tick takes the cleartext form it always had. What P5d's must meet, each seam alike:
///
/// - **With the switch off, each answers "cannot seal" by itself:** `false`, `nil`, `false`. The ledger asks
///   ``sealTick(to:acks:)`` without asking ``canSeal(_:)`` first, for a linked author, for an absent one `canSeal` refused,
///   and for a batch or a ride hold that goes over a link, as Kotlin's does (`AckSync.kt:187`, `:586`). Since the engine's
///   `configuration` is a `let`, holding ``NoTickSealing`` from the start when the switch is off meets it too.
/// - **Each seal stands in a store unit of its own, the outermost.** A seam answers a wire, or `true`, only once that unit
///   answers `.committed`, and settles the seal after the commit. A unit that answers `.joined`, `.failed` or `.abandoned`,
///   and a seal that fails, answer `nil` or `false` with nothing on the air. A tick sent off a joined seal could fly before
///   an outer commit that then fails, and the chain's next seal would use its message key again.
/// - **The fallback is the cleartext tick, never v1.** A seam that cannot seal with the ratchet says so, and the ledger
///   sends the cleartext tick: a v1 ctl frame is an empty bubble on a build without the ratchet (`InboundPipeline.kt:2898-2900`).
/// - **A seam never touches the ledger that asks it,** to read or to write, directly or through the engine's `footprint`,
///   `nextDeadline` or `sweep`. The ledger is in the middle of a change of its own when it asks, and Swift's exclusivity
///   check traps. So the room ticks a sealed batch carries are the ledger's to take and to give back, where Kotlin's
///   `originateDeliveryTick` takes them itself (`MeshManager.kt:1948-1957`).
/// - **No blocked gate:** a blocked author's tick is sealed, batched and escalated like anyone's (`MeshManager.kt:1863-1865`;
///   ADR 2026-10.5wgg, amended). A cleartext tick to a blocked author alone would show the block on the air.
/// - **P5d's seams live under `Sources/KnitMesh/Ratchet/`,** beside the send unit they share, which the crypto reviewer's
///   gate covers, as it covers this file.
public protocol TickSealing {
    /// Whether `author` could read a sealed tick now (`canSealTickTo`, `MeshManager.kt:2066-2069`): its pinned row carries
    /// `CAP_RATCHET` and a bundle, as `canSealTickTo` reads `pubKey`. No prekey: IntroSync's gate (`:345`) adds one, and
    /// nothing stricter than ``sealTick(to:acks:)`` checks may stand here, since the ledger seals an absent author's entry
    /// when this answers `false`. A cheap read, never a trial seal: a stale yes costs only a seal that fails later, which
    /// leaves the ticks cleartext entries. `false` with the switch off.
    func canSeal(_ author: NodeId) -> Bool

    /// One sealed tick acknowledging `ids` to `author` (`sealDeliveryTick`, `MeshManager.kt:1925-1931`): a DM-form chat to
    /// `author` under a fresh id and `sentAt`, one id in `ack` and a batch in `acks` (`:1876-1883`), signed once with
    /// `relay = false` for its live link, never unsigned. `nil` when the author cannot read one, the switch is off, or the
    /// seal's unit did not commit. Each seal spends a chain key, so the ledger asks once per owed entry or held batch and
    /// re-sends what it got, verbatim.
    func sealTick(to author: NodeId, acks ids: [String]) -> WireEnvelope?

    /// One sealed tick acknowledging `ids` to `author`, originated (`originateDeliveryTick`, `MeshManager.kt:1939-1959`): the
    /// same DM-form chat, signed once with `relay = true` and taken into our custody inside the seal's unit, then, once it
    /// commits, marked as ours and flooded, as P5b's `sendRatchet` and `fly` send a DM. So it is carried for a day like the
    /// message it acknowledges. `ids` is a batch and the room ticks riding it, at most ``AckSync/maxBatchAcks``, and the seam
    /// takes no riders of its own. Answers whether it went: `false` only when nothing went, and the ledger then keeps the
    /// ids as cleartext entries. `false` with the switch off.
    func originateTick(to author: NodeId, acks ids: [String]) -> Bool
}

/// The seams as this build ships them, until phase P5d: no author can read a sealed tick, so nothing is sealed, whatever
/// the ratchet's switch says.
internal struct NoTickSealing: TickSealing {
    func canSeal(_: NodeId) -> Bool { false }

    func sealTick(to _: NodeId, acks _: [String]) -> WireEnvelope? { nil }

    func originateTick(to _: NodeId, acks _: [String]) -> Bool { false }
}
