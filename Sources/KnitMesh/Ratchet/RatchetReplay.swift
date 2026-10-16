import KnitStore
import KnitWire

/// The DM ratchet frames whose open's store unit failed, kept as the copies that failed, to be opened again at the next
/// sweep (ADR 2026-10.5sk9, phase P5a).
///
/// Our custody cannot stand in for these copies. It keeps the first bytes it stored under an id, and a peer's re-seal
/// after a reset reuses the id it re-seals, so custody may hold only the seal that could not open; a copy handed us
/// point to point never reached custody at all. And a frame custody does hold is listed in our digest, so no
/// neighbour serves it again: this node must open it, from the copy that failed. The copies live in memory and die
/// with the process; the start's replay then finds what custody holds with no row, and opens it holding the era.
///
/// Each copy keeps the route it came by, its origin included, so a frame the start's replay handed back is opened
/// again as one, never as a first verdict. An id kept twice keeps the later copy, which goes to the back of the line,
/// save that an unsigned copy never displaces a signed one: only the live-link tick travels unsigned, under an id of its
/// own, so an unsigned twin of a signed frame is a stripped capture. A copy goes as soon as any copy of its id opens and
/// commits (``forget(_:)``): a ctl frame never has a row for the sweep to find. Ids compare by their bytes (ADR
/// 2026-09.jc2x).
internal struct RatchetReplay {
    /// One copy kept: the frame as it came, and the route it came by.
    struct Kept: Equatable, Sendable {
        /// The frame whose unit failed, as it was opened.
        let envelope: RelayEnvelope
        /// How it came: the neighbour that handed it over, whether it was signed, and whether its open was its first
        /// verdict.
        let route: RatchetInbound.Route

        /// What holding it costs, near enough: its payload.
        var bytes: Int { envelope.payload.count }
    }

    /// The most copies kept, in custody's unit (``CustodyLimits/maxFrames``): a memory bound, since the copies are held
    /// until the store answers, through a whole outage, and a copy handed over point to point never touched custody.
    static let capacity = CustodyLimits().maxFrames
    /// The most bytes kept, the parking lot's memory bound (4 MiB, ``PendingInbound/defaultMaxBytes``).
    static let maxBytes = PendingInbound.defaultMaxBytes

    /// Oldest first.
    private var kept: [Kept] = []
    private var keys: Set<ExactKey> = []
    private var keptBytes = 0

    /// How many copies are kept.
    var count: Int { kept.count }

    /// Keeps `envelope`, as it came by `route`, for the next sweep. An id kept already gives up its copy for this one,
    /// unless this one is unsigned and that one signed. Past either bound the oldest copies go first.
    mutating func keep(_ envelope: RelayEnvelope, route: RatchetInbound.Route) {
        let key = ExactKey(envelope.id)
        if keys.contains(key), let index = kept.firstIndex(where: { ExactKey($0.envelope.id) == key }) {
            guard route.signed || !kept[index].route.signed else {
                return
            }
            keptBytes -= kept.remove(at: index).bytes
        }
        keys.insert(key)
        let copy = Kept(envelope: envelope, route: route)
        kept.append(copy)
        keptBytes += copy.bytes
        while kept.count > Self.capacity || (keptBytes > Self.maxBytes && kept.count > 1) {
            let oldest = kept.removeFirst()
            keptBytes -= oldest.bytes
            keys.remove(ExactKey(oldest.envelope.id))
        }
    }

    /// Lets the copy kept under `id` go, if one is: another copy of its frame opened and committed, so opening this one
    /// again could only meet a spent key or, past an era change, apply it a second time.
    mutating func forget(_ id: String) {
        let key = ExactKey(id)
        guard keys.remove(key) != nil, let index = kept.firstIndex(where: { ExactKey($0.envelope.id) == key }) else {
            return
        }
        keptBytes -= kept.remove(at: index).bytes
    }

    /// Every copy kept, oldest first, and forgets them: a frame that fails again is kept again.
    mutating func take() -> [Kept] {
        defer {
            kept.removeAll()
            keys.removeAll()
            keptBytes = 0
        }
        return kept
    }
}
