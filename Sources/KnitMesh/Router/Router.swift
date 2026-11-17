public import KnitWire

/// A frame to write, and the neighbour to write it to.
public struct Send: Sendable, Equatable {
    /// The frame.
    public var wire: WireEnvelope
    /// The neighbour.
    public var to: NodeId

    /// Makes a send.
    public init(wire: WireEnvelope, to: NodeId) {
        self.wire = wire
        self.to = to
    }
}

/// Floods frames through the mesh and ends each flood (`MeshRouter.kt`).
///
/// A frame off a link is first ``admit(_:now:)``ted: refused if its id is not the shape its type is minted with, metered
/// if it is a room post, then checked against the seen set. The caller delivers a new frame locally, then hands it to
/// ``relay(_:neighbors:jitter:now:)``.
/// Rather than rebroadcasting at once, which storms a dense cluster, a relay waits a random 0–150 ms and is
/// cancelled if meanwhile the frame is heard from two distinct neighbours: someone nearby already relayed it.
/// When it fires (``fireDue(now:neighbors:)``) it goes to every neighbour the frame was not heard from, with only
/// `ttl` and `hops` rewritten.
///
/// The router never writes anything itself. Each method returns the ``Send``s it wants made, so it is plain
/// state that a test drives with any clock it likes.
public struct Router: Sendable {
    /// The router's tunables.
    public struct Configuration: Sendable {
        /// The longest a first-seen frame waits before it is relayed (`DEFAULT_JITTER_WINDOW_MS`).
        public var jitterWindowMilliseconds: Int64
        /// How many distinct neighbours a frame must be heard from, the first included, to cancel its relay
        /// (`DEFAULT_SUPPRESS_THRESHOLD`).
        public var suppressThreshold: Int

        /// knit-next's values unless told otherwise: 150 ms and 2.
        public init(jitterWindowMilliseconds: Int64 = 150, suppressThreshold: Int = 2) {
            self.jitterWindowMilliseconds = jitterWindowMilliseconds
            self.suppressThreshold = suppressThreshold
        }
    }

    /// What ``admit(_:now:)`` decided.
    public enum Admission: Sendable, Equatable {
        /// First sight: deliver it, then relay it.
        case new
        /// Seen inside the window: drop it. It counted toward cancelling a pending relay.
        case duplicate
        /// A room post over the link's ingress budget: drop it, unmarked, so custody can bring it back later.
        case refused
        /// An id that is not the shape its type is minted with (``FrameId/admits(_:)``): drop it unseen and unmetered.
        /// Android refuses it at the same point (`MeshRouter.kt:96` at knit-next `a81f2050`, knit-next ADR 2026-10.9qr4),
        /// so a copy this port kept would be re-served to every Android neighbour at every exchange.
        case nonCanonical
    }

    /// What the router has done, for diagnostics and tests.
    public struct Counters: Sendable, Equatable {
        /// Frames admitted as new.
        public var admitted = 0
        /// Frames dropped as duplicates.
        public var deduplicated = 0
        /// Room posts refused by the ingress budget.
        public var refused = 0
        /// Frames refused for an id not of their type's shape (Android's `DropReason.NONCANONICAL_ID`).
        public var nonCanonical = 0
        /// Relays that fired, whether or not anyone was left to send to.
        public var relayed = 0
        /// Relays cancelled because two neighbours were heard relaying first.
        public var suppressed = 0
        /// Point-to-point frames handed their last hop.
        public var handedOn = 0
        /// Frames a spool served admitted as new, counted apart from ``admitted`` (ADR 2026-11.adrq, P4a).
        public var spoolAdmitted = 0
        /// Frames a spool served that were already seen, counted apart from ``deduplicated``.
        public var spoolDeduplicated = 0
        /// Frames a spool served with an id not of their type's shape, counted apart from ``nonCanonical``.
        public var spoolNonCanonical = 0
        /// Spool frames scheduled onto the radios (the bridge), counted apart from the relays they become.
        public var spoolBridged = 0
    }

    private struct PendingRelay: Sendable {
        var relayed: WireEnvelope
        /// Every neighbour the frame was heard from, each once: all are skipped when it fires, and their number
        /// is what suppression counts.
        var heardFrom: [NodeId]
        var fireAt: Int64
        var sequence: Int
    }

    /// The tunables.
    public let configuration: Configuration
    /// What the router has done so far.
    public private(set) var counters = Counters()

    private var seen: SeenSet
    /// The ids a spool served (ADR 2026-11.adrq, P4b1): a set of its own, of the same size and window, so a spool's backlog
    /// never evicts an id the radios brought. Both doors check both sets, so a radio copy of a pulled frame is a duplicate,
    /// and a pulled copy of a radio frame.
    private var spoolSeen = SeenSet()
    private var budget: IngressBudget<NodeId>
    private var pending: [ExactKey: PendingRelay] = [:]
    private var nextSequence = 0

    /// A router with knit-next's sizes unless told otherwise.
    public init(
        configuration: Configuration = Configuration(),
        seen: SeenSet = SeenSet(),
        budget: IngressBudget<NodeId> = IngressBudget()
    ) {
        self.configuration = configuration
        self.seen = seen
        self.budget = budget
    }

    /// The frame ids in the router's ``SeenSet``.
    public var seenCount: Int { seen.count }

    /// The frame ids in the spool's own ``SeenSet``.
    public var spoolSeenCount: Int { spoolSeen.count }

    /// Relays waiting out their jitter.
    public var pendingRelayCount: Int { pending.count }

    /// When the next pending relay fires, on the monotonic clock, or `nil` when none waits.
    public var nextDeadline: Int64? { pending.values.map(\.fireAt).min() }

    /// Decides whether a frame off a link is new.
    ///
    /// The ingress meter sits between the seen check and the seen insert, as in knit-next: a duplicate never
    /// costs a token, since it is evidence the frame is already spreading, and a refused post is never marked
    /// seen, so a later custody re-serve can still bring it in.
    ///
    /// Before both, the id's shape (`MeshRouter.handleInbound`, `MeshRouter.kt:96` at knit-next `a81f2050`): a twin
    /// under `"\u{FEFF}" + X` is neither marked seen, so the real `X` after it is still new, nor metered, so it costs the
    /// link no token an honest post would need, nor counted as overheard toward cancelling a relay.
    public mutating func admit(_ frame: InboundFrame, now: Int64) -> Admission {
        guard FrameId.admits(frame.envelope) else {
            counters.nonCanonical += 1
            return .nonCanonical
        }
        let id = frame.envelope.id
        let pulled = spoolSeen.contains(id, now: now)
        if !pulled, !seen.contains(id, now: now), IngressBudget<NodeId>.meters(frame.envelope), !budget.admit(link: frame.from, now: now) {
            counters.refused += 1
            return .refused
        }
        guard !pulled, seen.insert(id, now: now) else {
            counters.deduplicated += 1
            overheard(id, from: frame.from)
            return .duplicate
        }
        counters.admitted += 1
        return .new
    }

    /// Decides whether a frame a spool served is new (ADR 2026-11.adrq, P4a): the id's shape and the seen set, and nothing
    /// a link's door adds. No ingress budget, which meters a link, and no overhear: a spool is no neighbour, so its copy
    /// neither counts toward cancelling a relay nor is ever skipped when one fires (`MeshRouter.kt:64`, `:132-136` at
    /// knit-next `0832b8462`). The heal loop's hourly budget bounds what a spool can bring. The id goes into the spool's own
    /// set, never the radios' (P4b1), and an id either set holds is a duplicate.
    public mutating func admitPulled(envelope: RelayEnvelope, now: Int64) -> Admission {
        guard FrameId.admits(envelope) else {
            counters.spoolNonCanonical += 1
            return .nonCanonical
        }
        guard !seen.contains(envelope.id, now: now), spoolSeen.insert(envelope.id, now: now) else {
            counters.spoolDeduplicated += 1
            return .duplicate
        }
        counters.spoolAdmitted += 1
        return .new
    }

    /// Schedules the bridge of a frame a spool served, admitted by ``admitPulled(envelope:now:)`` and delivered: a flood
    /// heard from nobody, so it goes to every neighbour when it fires, and the first radio copy that follows is the first
    /// overhear, not the second. `wire` is the re-served copy (ttl reset, hops 0). Answers whether it was scheduled.
    public mutating func relayPulled(_ wire: WireEnvelope, id: String, jitter: Int64, now: Int64) -> Bool {
        guard relaysPulled(wire) else {
            return false
        }
        pending[ExactKey(id)] = PendingRelay(relayed: wire.relayed(), heardFrom: [], fireAt: now + jitter, sequence: nextSequence)
        nextSequence += 1
        counters.spoolBridged += 1
        return true
    }

    /// Schedules the relay of a frame just admitted and delivered, and answers the one write that cannot wait.
    ///
    /// A flooded frame waits `jitter` milliseconds, drawn by the caller from `0..<jitterWindowMilliseconds`,
    /// and only while `hops < min(ttl, 8)`: `ttl` is attacker-controlled, so it is capped before it is trusted.
    /// A point-to-point frame (`relay = false`) is never flooded; the one exception is a DM-form chat addressed
    /// to a neighbour, which goes that one hop now (ADR 2026-09.wkbk).
    public mutating func relay(_ frame: InboundFrame, neighbors: [NodeId], jitter: Int64, now: Int64) -> [Send] {
        guard frame.wire.relay else {
            return handOn(frame, neighbors: neighbors)
        }
        guard hasHopsLeft(frame.wire) else {
            return []
        }
        pending[ExactKey(frame.envelope.id)] = PendingRelay(
            relayed: frame.wire.relayed(),
            heardFrom: [frame.from],
            fireAt: now + jitter,
            sequence: nextSequence
        )
        nextSequence += 1
        return []
    }

    /// Marks a frame this node originated as seen, so its echo is neither delivered nor relayed. The caller
    /// writes it, at once and to everyone it goes to.
    public mutating func markOwn(_ id: String, now: Int64) {
        _ = seen.insert(id, now: now)
    }

    /// Fires every relay whose jitter has run out, oldest first: each to every current neighbour it was not
    /// heard from.
    public mutating func fireDue(now: Int64, neighbors: [NodeId]) -> [Send] {
        let due = pending.filter { $0.value.fireAt <= now }.sorted { lhs, rhs in
            (lhs.value.fireAt, lhs.value.sequence) < (rhs.value.fireAt, rhs.value.sequence)
        }
        var sends: [Send] = []
        for (key, relay) in due {
            pending[key] = nil
            counters.relayed += 1
            for neighbor in neighbors where !relay.heardFrom.contains(neighbor) {
                sends.append(Send(wire: relay.relayed, to: neighbor))
            }
        }
        return sends
    }

    /// Cancels every pending relay (`MeshRouter.stop`).
    public mutating func cancelAll() {
        pending.removeAll()
    }

    /// Whether ``relayPulled(_:id:jitter:now:)`` would schedule `wire`: a flood with hops left. The spool's door asks first,
    /// so it spends a bridge token only on a frame the router will send.
    public func relaysPulled(_ wire: WireEnvelope) -> Bool {
        wire.relay && hasHopsLeft(wire)
    }

    /// Takes back the seen mark ``admitPulled(envelope:now:)`` just made for `id`, when the spool's door could not take the
    /// frame (a store unit failed): the next round's copy is new again, however many times the store fails, so a frame is
    /// never left seen and unheld (ADR 2026-11.adrq, P4a). Only after an admission that answered ``Admission/new``.
    mutating func reopenPulled(_ id: String) {
        spoolSeen.forget(id)
    }

    /// Lets one more copy of `id` in inside its window (``SeenSet/reopen(_:now:)``), from whichever set holds it, since both
    /// doors read both sets: a DM a relay served first and the radio then brings re-sealed would otherwise stay a duplicate
    /// of the spool's mark. Each set keeps its own once-per-window memory, so an id is reopened at most once per set per
    /// window, twice at most when both sets hold it.
    public mutating func reopen(_ id: String, now: Int64) -> Bool {
        let radio = seen.reopen(id, now: now)
        let pulled = spoolSeen.reopen(id, now: now)
        return radio || pulled
    }

    /// A duplicate of `id` arrived from `neighbor`. Only a second *distinct* neighbour is evidence that someone
    /// else relayed it: the link-up push and the custody re-serve that follows it bring the same frame from the
    /// same peer, and counting that cancelled a newcomer's profile relay past the first hop.
    private mutating func overheard(_ id: String, from neighbor: NodeId) {
        let key = ExactKey(id)
        guard var relay = pending[key], !relay.heardFrom.contains(neighbor) else {
            return
        }
        relay.heardFrom.append(neighbor)
        if relay.heardFrom.count >= configuration.suppressThreshold {
            pending[key] = nil
            counters.suppressed += 1
        } else {
            pending[key] = relay
        }
    }

    /// The last hop for a point-to-point DM-form frame (`MeshRouter.handOn`): to its addressee if we hold a live
    /// link to it, never back where it came from, and under the same hop cap as a flood.
    private mutating func handOn(_ frame: InboundFrame, neighbors: [NodeId]) -> [Send] {
        guard frame.envelope.isDirect, let recipient = frame.envelope.recipientId.flatMap(NodeId.init), recipient != frame.from,
            hasHopsLeft(frame.wire), neighbors.contains(recipient)
        else {
            return []
        }
        counters.handedOn += 1
        return [Send(wire: frame.wire.relayed(), to: recipient)]
    }

    private func hasHopsLeft(_ wire: WireEnvelope) -> Bool {
        wire.hops < min(wire.ttl, WireEnvelope.defaultTTL)
    }
}
