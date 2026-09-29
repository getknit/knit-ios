public import KnitWire

/// Which nearby peers to hold a link to (`PromotionPolicy.kt`): peers that stay close long enough, strongest
/// first, within a link budget. Eviction is weakest first and hysteretic, so a crowd of passers-by cannot
/// thrash the link set.
///
/// The caller filters the candidates to peers it should dial and is not already linked to.
///
/// Two rules are this port's, not Android's (ADR 2026-09.6es2, amended 2026-09-29): a peer not heard lately is never
/// promoted, and ``untilDwellEnds(candidates:backoff:configuration:)`` tells the caller when to run promotion again
/// with nothing heard, since a dwell that ends between a peer's adverts is no event of its own.
public enum PromotionPolicy {
    /// A link held now, for the eviction decision.
    public struct LinkSnapshot: Sendable, Equatable {
        /// The linked peer.
        public var nodeId: NodeId
        /// Its smoothed RSSI, in dBm.
        public var smoothedRssi: Double
        /// How long the link has been up.
        public var ageMilliseconds: Int64

        /// Makes a snapshot.
        public init(nodeId: NodeId, smoothedRssi: Double, ageMilliseconds: Int64) {
            self.nodeId = nodeId
            self.smoothedRssi = smoothedRssi
            self.ageMilliseconds = ageMilliseconds
        }
    }

    /// Links to open and links to close, this tick.
    public struct Decision: Sendable, Equatable {
        /// Peers to dial, strongest first.
        public var promote: [NodeId]
        /// Links to close, weakest first.
        public var evict: [NodeId]
    }

    /// The policy's tunables (`PromotionConfig`).
    public struct Configuration: Sendable {
        /// Continuous presence before promoting, which filters out passers-by.
        public var dwellMilliseconds: Int64
        /// The weakest smoothed RSSI ever promoted, in dBm: the edge of usable range.
        public var rssiFloor: Double
        /// The most links held at once.
        public var maxLinks: Int
        /// How much stronger, in dB, a candidate must be to replace the weakest link.
        public var rssiHysteresis: Double
        /// A link younger than this is never evicted.
        public var minimumHoldMilliseconds: Int64
        /// The longest a peer may go unheard and still be promoted. A sighting lingers 90 s and its dwell counts from
        /// the first advert, so without this a phone that left is dialed until it lingers out, and each dial that
        /// times out doubles its backoff. Knit for Android has no such limit.
        public var heardWithinMilliseconds: Int64

        /// knit-next's values unless told otherwise: 12 s, −90 dBm, 6 links, 8 dB and 20 s. The 8 s silence limit is
        /// this port's, and matches the presence gap reset, past which the peer's next advert restarts its dwell.
        public init(
            dwellMilliseconds: Int64 = 12_000,
            rssiFloor: Double = -90,
            maxLinks: Int = 6,
            rssiHysteresis: Double = 8,
            minimumHoldMilliseconds: Int64 = 20_000,
            heardWithinMilliseconds: Int64 = 8000
        ) {
            self.dwellMilliseconds = dwellMilliseconds
            self.rssiFloor = rssiFloor
            self.maxLinks = maxLinks
            self.rssiHysteresis = rssiHysteresis
            self.minimumHoldMilliseconds = minimumHoldMilliseconds
            self.heardWithinMilliseconds = heardWithinMilliseconds
        }
    }

    /// Decides this tick's promotions and evictions. Ties keep their input order, as Kotlin's stable sort does.
    public static func decide(
        candidates: [PresenceTracker.Snapshot],
        links: [LinkSnapshot],
        backoff: Set<NodeId>,
        configuration: Configuration = Configuration()
    ) -> Decision {
        let promotable = stableSorted(candidates.filter { isPromotable($0, backoff: backoff, configuration: configuration) }) { lhs, rhs in
            lhs.smoothedRssi > rhs.smoothedRssi
        }
        let evictable = stableSorted(links.filter { $0.ageMilliseconds >= configuration.minimumHoldMilliseconds }) { lhs, rhs in
            lhs.smoothedRssi < rhs.smoothedRssi
        }

        // Shed a strict overflow first, such as inbound links accepted past the budget, weakest first.
        let overflow = max(0, links.count - configuration.maxLinks)
        var evict = evictable.prefix(overflow).map(\.nodeId)
        var promote: [NodeId] = []
        let free = configuration.maxLinks - (links.count - evict.count)
        if free > 0 {
            promote = promotable.prefix(free).map(\.nodeId)
        } else if let weakest = evictable.dropFirst(overflow).first, let best = promotable.first {
            // At the budget, replace the weakest link only when the best candidate clearly beats it, so RSSI
            // jitter cannot ping-pong a link.
            if best.smoothedRssi >= weakest.smoothedRssi + configuration.rssiHysteresis {
                promote = [best.nodeId]
                evict.append(weakest.nodeId)
            }
        }
        return Decision(promote: promote, evict: evict)
    }

    /// How long until one of `candidates` becomes promotable with none of them heard meanwhile, or `nil` if none will.
    /// Only a running dwell can end with nothing heard, so this is the soonest dwell to end among peers above the
    /// floor, not backing off, and still heard recently enough when it does.
    ///
    /// Promotion runs when something happens, and a dwell that ends between a peer's adverts is nothing happening. An
    /// iPhone hears a peer that advertises about once a second with gaps of several seconds, so it dialed up to 10 s
    /// after the dwell had ended. A caller that wakes this long from now dials on time. A peer whose dwell ends with
    /// no free slot is past the point afterwards and answers nothing, so the caller never wakes in a loop.
    public static func untilDwellEnds(
        candidates: [PresenceTracker.Snapshot],
        backoff: Set<NodeId>,
        configuration: Configuration = Configuration()
    ) -> Int64? {
        candidates.compactMap { candidate -> Int64? in
            let wait = configuration.dwellMilliseconds - candidate.dwellMilliseconds
            let heardThen = candidate.lastSeenAgoMilliseconds + wait <= configuration.heardWithinMilliseconds
            let eligible = candidate.smoothedRssi >= configuration.rssiFloor && !backoff.contains(candidate.nodeId)
            return wait > 0 && heardThen && eligible ? wait : nil
        }
        .min()
    }

    /// Close enough, present long enough, heard lately, and not backing off.
    private static func isPromotable(_ candidate: PresenceTracker.Snapshot, backoff: Set<NodeId>, configuration: Configuration) -> Bool {
        candidate.smoothedRssi >= configuration.rssiFloor && candidate.dwellMilliseconds >= configuration.dwellMilliseconds
            && candidate.lastSeenAgoMilliseconds <= configuration.heardWithinMilliseconds && !backoff.contains(candidate.nodeId)
    }

    private static func stableSorted<Element>(_ elements: [Element], by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        elements.enumerated()
            .sorted { lhs, rhs in
                if areInIncreasingOrder(lhs.element, rhs.element) {
                    return true
                }
                if areInIncreasingOrder(rhs.element, lhs.element) {
                    return false
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
