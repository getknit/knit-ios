public import KnitWire

/// Which nearby peers to hold a link to (`PromotionPolicy.kt`): peers that stay close long enough, strongest
/// first, within a link budget. Eviction is weakest first and hysteretic, so a crowd of passers-by cannot
/// thrash the link set.
///
/// The caller filters the candidates to peers it should dial and is not already linked to.
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

        /// knit-next's values unless told otherwise: 12 s, −90 dBm, 6 links, 8 dB and 20 s.
        public init(
            dwellMilliseconds: Int64 = 12_000,
            rssiFloor: Double = -90,
            maxLinks: Int = 6,
            rssiHysteresis: Double = 8,
            minimumHoldMilliseconds: Int64 = 20_000
        ) {
            self.dwellMilliseconds = dwellMilliseconds
            self.rssiFloor = rssiFloor
            self.maxLinks = maxLinks
            self.rssiHysteresis = rssiHysteresis
            self.minimumHoldMilliseconds = minimumHoldMilliseconds
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

    /// Close enough, present long enough, and not backing off.
    private static func isPromotable(_ candidate: PresenceTracker.Snapshot, backoff: Set<NodeId>, configuration: Configuration) -> Bool {
        candidate.smoothedRssi >= configuration.rssiFloor && candidate.dwellMilliseconds >= configuration.dwellMilliseconds
            && !backoff.contains(candidate.nodeId)
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
