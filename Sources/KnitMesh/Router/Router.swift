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
/// A frame off a link is first ``admit(_:now:)``ted: metered if it is a room post, then checked against the seen
/// set. The caller delivers a new frame locally, then hands it to ``relay(_:neighbors:jitter:now:)``.
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
    }

    /// What the router has done, for diagnostics and tests.
    public struct Counters: Sendable, Equatable {
        /// Frames admitted as new.
        public var admitted = 0
        /// Frames dropped as duplicates.
        public var deduplicated = 0
        /// Room posts refused by the ingress budget.
        public var refused = 0
        /// Relays that fired, whether or not anyone was left to send to.
        public var relayed = 0
        /// Relays cancelled because two neighbours were heard relaying first.
        public var suppressed = 0
        /// Point-to-point frames handed their last hop.
        public var handedOn = 0
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

    /// When the next pending relay fires, on the monotonic clock, or `nil` when none waits.
    public var nextDeadline: Int64? { pending.values.map(\.fireAt).min() }

    /// Decides whether a frame off a link is new.
    ///
    /// The ingress meter sits between the seen check and the seen insert, as in knit-next: a duplicate never
    /// costs a token, since it is evidence the frame is already spreading, and a refused post is never marked
    /// seen, so a later custody re-serve can still bring it in.
    public mutating func admit(_ frame: InboundFrame, now: Int64) -> Admission {
        let id = frame.envelope.id
        if !seen.contains(id, now: now), IngressBudget<NodeId>.meters(frame.envelope), !budget.admit(link: frame.from, now: now) {
            counters.refused += 1
            return .refused
        }
        guard seen.insert(id, now: now) else {
            counters.deduplicated += 1
            overheard(id, from: frame.from)
            return .duplicate
        }
        counters.admitted += 1
        return .new
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

    /// Lets one more copy of `id` in inside its window (``SeenSet/reopen(_:now:)``).
    public mutating func reopen(_ id: String, now: Int64) -> Bool {
        seen.reopen(id, now: now)
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
