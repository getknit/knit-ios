import KnitWire

/// The `CTL_GROUP_KEY` frames held back for a group we do not hold yet, or from a sender we hold as departed: the
/// seed-before-roster race (`PendingGroupKeys` in knit-next's `mesh/PendingGroupKeys.kt`, at `cbf2a487`; ADR
/// 2026-10.5sk9, phase P6a2).
///
/// A creator distributes its seed before the first group frame carries the roster, and custody serves the two in either
/// order. Adoption is gated on the group's row, and the DM ratchet consumes a ctl frame whether or not its seed was
/// adopted, so the engine parks such a seed before its open commits (``MeshEngine/handleRatchetDirect(_:_:sender:route:)``),
/// with the chain left where it was, and releases it once the roster's write lets its sender in
/// (``MeshEngine/releaseHeldSeeds(of:)``). A seed whose sender we hold as departed waits for that sender's own rejoin: a
/// release leaves it exactly where it was, its clock untouched, so another member's traffic never keeps it alive.
///
/// It lives in memory, as Kotlin's does. A frame parked here was carried in our custody before it parked and its chain
/// never moved, so what a restart loses comes back: the start's replay leaves it unopened, and the first sight of its group
/// opens it from custody (``MeshEngine/replayCustodiedSeedDirectMessages(of:except:)``). Bounded three ways, oldest
/// first: ``defaultHoldMilliseconds``, ``defaultCapacity`` in all and ``defaultPerGroup`` per group. Ids and groups compare
/// by their bytes (ADR 2026-09.jc2x).
internal struct PendingGroupKeys {
    /// A parked seed: the frame as the ratchet's arm received it, the route it came by, and when it parked.
    struct Parked {
        /// The group its seed names, by its bytes.
        let group: ExactKey
        /// The frame, verified when it arrived.
        let envelope: RelayEnvelope
        /// How it came: released, it opens as it would have then.
        let route: RatchetInbound.Route
        /// When it parked, on the monotonic clock.
        let parkedAt: Int64
    }

    /// How long a seed waits for its group's first frame (`HOLD_TTL_MS`, `PendingGroupKeys.kt:115`): the two normally land
    /// seconds apart, and a skipped key outlives this by far.
    static let defaultHoldMilliseconds: Int64 = 3_600_000
    /// The most seeds parked at once (`MAX_FRAMES`), the memory bound.
    static let defaultCapacity = 64
    /// The most seeds parked for one group (`MAX_PER_GROUP`): a roster of eight, each owed a seed and a root gossip.
    static let defaultPerGroup = 16

    private let holdMilliseconds: Int64
    private let capacity: Int
    private let perGroup: Int
    /// Oldest first.
    private var parked: [Parked] = []

    /// A park with knit-next's bounds.
    init() {
        self.init(holdMilliseconds: Self.defaultHoldMilliseconds, capacity: Self.defaultCapacity, perGroup: Self.defaultPerGroup)
    }

    /// A park with these bounds, a test's.
    init(holdMilliseconds: Int64, capacity: Int, perGroup: Int) {
        self.holdMilliseconds = holdMilliseconds
        self.capacity = capacity
        self.perGroup = perGroup
    }

    /// How many seeds are parked.
    var count: Int { parked.count }

    /// Whether nothing is parked.
    var isEmpty: Bool { parked.isEmpty }

    /// What ``hold(_:for:route:now:)`` did with a seed.
    enum Hold: Equatable {
        /// Parked now.
        case parked
        /// Parked already: a re-serve, swallowed the same way, uncounted.
        case alreadyParked
        /// Its group holds ``defaultPerGroup`` already: the caller lets the frame take the ordinary path.
        case full
    }

    /// Parks `envelope`, a verified seed for `group` that came by `route`, at `now` (`hold`, `:58-66`). A seed parked or
    /// already parked has the caller skip the commit either way; ``Hold/full`` lets it take the ordinary path. Past
    /// ``defaultCapacity`` the oldest goes.
    mutating func hold(_ envelope: RelayEnvelope, for group: String, route: RatchetInbound.Route, now: Int64) -> Hold {
        let id = ExactKey(envelope.id)
        if parked.contains(where: { ExactKey($0.envelope.id) == id }) {
            return .alreadyParked
        }
        let key = ExactKey(group)
        guard parked.count(where: { $0.group == key }) < perGroup else {
            return .full
        }
        parked.append(Parked(group: key, envelope: envelope, route: route, parkedAt: now))
        parked.removeFirst(max(0, parked.count - capacity))
        return .parked
    }

    /// Takes every seed parked for `group` that `eligible` accepts, oldest first (`release`, `:74-89`). One it refuses
    /// stays where it was, its clock untouched.
    mutating func release(_ group: String, where eligible: (Parked) -> Bool) -> [Parked] {
        let key = ExactKey(group)
        var released: [Parked] = []
        parked.removeAll { entry in
            guard entry.group == key, eligible(entry) else {
                return false
            }
            released.append(entry)
            return true
        }
        return released
    }

    /// Drops every seed parked more than ``defaultHoldMilliseconds`` before `now`, and answers how many (`sweepExpired`,
    /// `:92-104`).
    @discardableResult
    mutating func sweep(now: Int64) -> Int {
        let before = parked.count
        parked.removeAll { now - $0.parkedAt > holdMilliseconds }
        return before - parked.count
    }
}
