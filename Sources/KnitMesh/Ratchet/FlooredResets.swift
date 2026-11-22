import KnitWire

/// The peer resets our replacement floor refused, one per peer, held whole until the floor ends (`FlooredResets` in
/// knit-next's `mesh/FlooredResets.kt` at `f018bc8ce`, its ADR 2026-11.sfms, #251; ADR 2026-10.5sk9's P9b amendment).
///
/// A peer's flagged init that lands inside the minute after the last replacement we adopted from it is refused, and for
/// good unless somebody brings it back: the router marked its id seen before the open, custody stored it and our digest
/// lists it, so no neighbour serves it again; it is a ctl with no message row, so nothing re-seals it; and the resetter,
/// unconfirmed, has its own heuristic floored for six hours. The engine names that refusal (`RESET_FLOORED`, only for a
/// root we never held), the ratchet's inbound arm holds the frame here inside the failure that refused it, and the
/// 60-second re-offer opens it again once the floor is open (``MeshEngine/reopenFlooredResets()``).
///
/// The frame is held whole, its signature and signed bytes with its envelope, never by id: custody's quota, its byte cap, or
/// a point-to-point delivery that never stored a copy may have nothing to read back. Only a signed frame is held, since the
/// flag rides outside a v2 frame's AEAD and the signature is what makes it the peer's. One entry per peer, the newest by
/// the sender's own `sentAt` winning: a later reset of the same peer replaced the earlier on the sender's side too.
///
/// Each entry carries the peer's root generation as the open that refused it began (``RatchetSessions/rootGeneration(of:)``).
/// Any root change since, an adoption, a race, our own re-root, a reclaim or a forget, means the init may name a root the
/// peer has left, and opening it again would split the pair, so the entry is dropped and never run (``stand(_:generation:)``).
/// While an entry stands, the follow-ups the resetter sealed under its reset carry that reset's init and fail here; they
/// are never reset evidence (``MeshEngine``'s `explains`), and the re-open replays them from our custody.
///
/// In memory, like the floor it waits on: a restart forgets both, and the start's replay out of our custody holds such a
/// reset again (``RatchetInbound/Origin/startReplay``). Peers compare as node ids, which a verified sender always is.
internal struct FlooredResets {
    /// One held reset: the frame as it came, the route's source to open it again from, its init's ephemeral (what a
    /// successful re-open leaves anchored), and the era it was refused in.
    struct Held: Equatable {
        /// The frame's signature and the signed bytes it covers, verified again before the re-open.
        let wire: WireEnvelope
        /// Its decoded envelope.
        let envelope: RelayEnvelope
        /// Where it came from: a link, our custody or a spool, which the re-open keeps.
        let source: RatchetInbound.Route.Source
        /// The ephemeral of the init it carries.
        let initEph: [UInt8]
        /// The peer's root generation read before the open that refused it.
        let generation: Int
        /// Whether the re-open's failure may be reset evidence: `false` for a hold the start's replay took out of our
        /// custody, which keeps a frame a spool served without saying so, and a spool's frame never is (ADR 2026-11.adrq),
        /// or one whose route said so already (``RatchetInbound/Route/mayBeEvidence``).
        let mayBeEvidence: Bool
    }

    /// What ``hold(_:for:)`` did.
    enum Hold: Equatable {
        /// Held now, where none was.
        case held
        /// Held now, in place of an older entry, which is answered.
        case replaced(Held)
        /// Not held: the entry there was sent later by the sender's clock.
        case older
    }

    /// What ``stand(_:generation:)`` found.
    enum Standing: Equatable {
        /// No entry.
        case absent
        /// The entry stands at the generation asked.
        case stands(Held)
        /// The entry's era moved, and it is dropped.
        case dropped(Held)
    }

    /// Read by the tests, which count it.
    private(set) var byPeer: [NodeId: Held] = [:]

    /// Holds `held` for `peer` unless the entry there was sent later (`hold`, `FlooredResets.kt:40-54`): an equal stamp
    /// replaces, so a delivery of the same frame again refreshes its generation.
    mutating func hold(_ held: Held, for peer: NodeId) -> Hold {
        guard let current = byPeer[peer] else {
            byPeer[peer] = held
            return .held
        }
        guard current.envelope.sentAt <= held.envelope.sentAt else {
            return .older
        }
        byPeer[peer] = held
        return .replaced(current)
    }

    /// Whether `peer`'s entry still stands at `generation`, the peer's root generation now (`valid`, `:74-88`); a stale one
    /// is dropped here and answered so the caller can say why.
    mutating func stand(_ peer: NodeId, generation: Int) -> Standing {
        guard let held = byPeer[peer] else {
            return .absent
        }
        guard held.generation == generation else {
            byPeer[peer] = nil
            return .dropped(held)
        }
        return .stands(held)
    }

    /// Every peer with an entry, in node id order, so the re-opens go in an order a test can read.
    var peers: [NodeId] { byPeer.keys.sorted() }

    /// Takes `peer`'s entry out of the hold, before it runs, so a failure costs that re-open and never repeats it.
    mutating func take(_ peer: NodeId) -> Held? {
        byPeer.removeValue(forKey: peer)
    }
}

/// How the floored resets went so far, in memory (ADR 2026-10.5sk9's P9b amendment). Android counts only the drop
/// (`RATCHET_RESET_FLOORED`, which this port counts as ``DropReason/ratchetResetFloored``), so these names are this port's.
public struct RatchetFlooredCounts: Sendable, Equatable {
    /// Resets held, a replaced entry's successor included.
    public internal(set) var flooredResetsHeld = 0
    /// Holds dropped unrun: their era moved, a newer reset replaced them, or the re-open could not verify them again.
    public internal(set) var flooredResetsDropped = 0
    /// Holds opened again once the floor ended.
    public internal(set) var flooredResetsReopened = 0
    /// Of those, the ones that left the session anchored on the held init: adopted.
    public internal(set) var flooredResetsAdopted = 0

    /// Counts as stated, zero unless given.
    public init(
        flooredResetsHeld: Int = 0, flooredResetsDropped: Int = 0, flooredResetsReopened: Int = 0, flooredResetsAdopted: Int = 0
    ) {
        self.flooredResetsHeld = flooredResetsHeld
        self.flooredResetsDropped = flooredResetsDropped
        self.flooredResetsReopened = flooredResetsReopened
        self.flooredResetsAdopted = flooredResetsAdopted
    }
}
