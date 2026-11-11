import KnitCrypto

/// When a blinding iPhone rotates its advert (`AdvertRotation`, `AdvertRotation.kt` at knit-next `cad69c77b`; ADR 2026-11.prsp,
/// "Rotation"): the slot rotation's turn, on the wall clock. Pure, the clock passed in, single-threaded on the `Mesh` actor.
///
/// **The turn.** A tag aired in slot `s` rotates at the first wake at or after the next slot edge `E`, every phone's edge at
/// once, so the edge links nothing in a crowd. The link manager reports ``Step/wait(atWall:)`` as a deadline the `Mesh`
/// actor's timer wakes for (ADR 2026-09.gq84), converted to the monotonic clock, which keeps counting while the phone sleeps;
/// a suspended iPhone runs no timer, so its first wake past the edge is the rotation, as a dozing Android's is.
///
/// - **Announce** (``Step/announce``) at the first wake at or after `E − leadMilliseconds`: the link manager reserves the
///   coming slot's tag and sends it in `TAG_NEXT`.
/// - **Rotate** (``Step/rotate(announced:)``) at the first wake at or after `max(E, announcedAt + minLeadMilliseconds)`: the
///   announced tag airs exactly. A wake after the edge with nothing announced, or a slot or more late, rotates at once and
///   unannounced; the link manager then sends the form just aired once to each link.
/// - **A clock set back** below the slot on the air rotates at once: the schedule's mark then gives a random tag.
///
/// Android also holds a rotation due while a Coded fast window, a hunt or one of its dials runs, and while an ACL edge
/// settles. None of those exists on an iPhone, so the turn here never holds.
///
/// A key change, a bring-up and a switch flip are not this type's turns: the link manager rotates at once for each and tells
/// ``onRotated(wall:)``.
internal struct AdvertRotation {
    /// The announcement's lead before the edge (`LEAD_MS`, `:199`): 30 s and a linked dozing phone's longest wake gap.
    static let leadMilliseconds: Int64 = 210_000
    /// The least time between an announcement and the rotation it names (`MIN_LEAD_MS`, `:202`).
    static let minLeadMilliseconds: Int64 = 30_000

    /// What the turn does now (`Step`, `:50-68`).
    enum Step: Equatable {
        /// Nothing until `atWall`, or an earlier poke (a key change, a clock change, a bring-up, a flip). `nil`: nothing is on
        /// the air to turn.
        case wait(atWall: Int64?)
        /// Reserve the coming slot's tag and announce it.
        case announce
        /// Rotate now, `announced` when the tag announced for this slot is the one to air.
        case rotate(announced: Bool)
    }

    /// Why a rotation ran: counted, never logged beside a time, a generation or a slot (`Cause`, `:76`).
    enum Cause: Hashable, CaseIterable {
        case slot
        case bringUp
        case fresh
        case flip
        case forced
    }

    /// The slot of the tag on the air, or `nil` while no blinded form is.
    private var airedSlot: Int64?
    private var announcedAt: Int64?
    private var announcedSlot: Int64?

    /// A blinded form went on the air at `wall`, whatever the cause: the next edge is the end of its slot.
    mutating func onRotated(wall: Int64) {
        airedSlot = BlindTag.slotOf(wallMilliseconds: wall)
        announcedAt = nil
        announcedSlot = nil
    }

    /// No blinded form is on the air any more (the switch off, the radio down): nothing to turn.
    mutating func onStopped() {
        airedSlot = nil
        announcedAt = nil
        announcedSlot = nil
    }

    /// The coming slot's tag was reserved and announced at `wall`.
    mutating func onAnnounced(wall: Int64) {
        announcedAt = wall
        announcedSlot = BlindTag.slotOf(wallMilliseconds: wall) + 1
    }

    /// The reservation was dropped (a key change, the radio down): what was announced will not air.
    mutating func dropAnnouncement() {
        announcedAt = nil
        announcedSlot = nil
    }

    /// Whether the coming slot's announcement has been made.
    var announced: Bool {
        guard let airedSlot, announcedAt != nil else {
            return false
        }
        return announcedSlot == airedSlot + 1
    }

    /// The slot edge the tag on the air ends at, on the wall clock, or `nil` with nothing blinded on the air.
    var nextEdge: Int64? {
        airedSlot.map { ($0 + 1) * BlindTag.slotMilliseconds }
    }

    /// When the next announcement is due on the wall clock, while it has not been made; `nil` with nothing on the air or the
    /// announcement made (`announceDueAt`, `:132-136`). A resend keeps out of the receiver's limit before it.
    var announceDueAt: Int64? {
        guard let edge = nextEdge, !announced else {
            return nil
        }
        return edge - Self.leadMilliseconds
    }

    /// The turn's next step at `wall` (`next`, `:156-173`).
    func next(wall: Int64) -> Step {
        guard let aired = airedSlot, let edge = nextEdge else {
            return .wait(atWall: nil)
        }
        if BlindTag.slotOf(wallMilliseconds: wall) < aired {
            // The clock went back below the slot on the air.
            return .rotate(announced: false)
        }
        // When the announced tag may air: the edge, or 30 s after the announcement if that came later.
        let announcedDue = announced ? announcedAt.map { max(edge, $0 + Self.minLeadMilliseconds) } : nil
        if wall >= edge {
            let due = announcedDue ?? edge
            guard wall >= due else {
                return .wait(atWall: due)
            }
            return .rotate(announced: announcedDue != nil && BlindTag.slotOf(wallMilliseconds: wall) == announcedSlot)
        }
        if let announcedDue {
            return .wait(atWall: announcedDue)
        }
        if wall >= edge - Self.leadMilliseconds {
            return .announce
        }
        return .wait(atWall: edge - Self.leadMilliseconds)
    }

    /// Why a new own key (`incoming`) restarts the advert, or `nil` when it does not (`causeOfKeyChange`, `:218-229`): equal
    /// to the key `held`, or the generation already on the air (`airedGeneration`, a bring-up that read it). The session's
    /// first key after a bring-up that aired a random tag for want of one completes that bring-up (``Cause/bringUp``); every
    /// other change, `nil` among them (a fresh pair the engine could not settle), is ``Cause/fresh``.
    static func causeOfKeyChange(held: OwnPresenceKey?, incoming: OwnPresenceKey?, airedGeneration: Int64?, sessionHadKey: Bool) -> Cause? {
        if incoming == held {
            return nil
        }
        guard let incoming else {
            return .fresh
        }
        if airedGeneration == incoming.generation {
            return nil
        }
        return held == nil && !sessionHadKey ? .bringUp : .fresh
    }
}

/// One pass request per key generation for a stale mark (`StaleLatch`, `AdvertRotation.kt:239-252`): ``TagSchedule/Next/stale``
/// repeats at every rotation while the engine's once-a-day floor refuses the advance, so asking at each would ask every slot.
internal struct StaleLatch {
    private var latched: Int64?

    /// Whether a `stale` answer under `generation` should ask the engine for a pass now: once per generation, the first time.
    mutating func offer(_ generation: Int64, stale: Bool) -> Bool {
        if let latched, latched != generation {
            self.latched = nil
        }
        guard stale, latched != generation else {
            return false
        }
        latched = generation
        return true
    }
}
