public import KnitWire

/// Who is nearby, as scan sightings describe it (`BlePresenceTracker.kt`): a smoothed RSSI per peer, how long
/// the peer has stayed in range, and how long ago it was last seen. The promotion policy reads it to pick whom
/// to link, and the UI reads it for the peer count.
///
/// Identity is the advertised node id, never a radio address, so a rotated Bluetooth address lands as a new
/// sighting of the same peer. Every method takes the time, in milliseconds on the monotonic clock.
public struct PresenceTracker: Sendable {
    /// One scan hit: the advert and its signal strength.
    public struct Sighting: Sendable, Equatable {
        /// The decoded advert, or the GATT payload of a peer that cannot advertise service data.
        public var advert: AdvertPayload
        /// The received signal strength, in dBm.
        public var rssi: Int

        /// Makes a sighting.
        public init(advert: AdvertPayload, rssi: Int) {
            self.advert = advert
            self.rssi = rssi
        }
    }

    /// A peer's presence now: what promotion decides on.
    public struct Snapshot: Sendable, Equatable {
        /// The latest advert.
        public var advert: AdvertPayload
        /// The smoothed RSSI, in dBm.
        public var smoothedRssi: Double
        /// How long the peer has been in range without a gap.
        public var dwellMilliseconds: Int64
        /// How long ago it was last seen.
        public var lastSeenAgoMilliseconds: Int64

        /// The peer's node id.
        public var nodeId: NodeId { advert.nodeId }

        /// Makes a snapshot.
        public init(advert: AdvertPayload, smoothedRssi: Double, dwellMilliseconds: Int64, lastSeenAgoMilliseconds: Int64) {
            self.advert = advert
            self.smoothedRssi = smoothedRssi
            self.dwellMilliseconds = dwellMilliseconds
            self.lastSeenAgoMilliseconds = lastSeenAgoMilliseconds
        }
    }

    /// The tracker's tunables (`PresenceConfig`).
    public struct Configuration: Sendable {
        /// The weight of each new RSSI sample: higher follows faster, lower smooths more.
        public var rssiSmoothing: Double
        /// A gap longer than this restarts the dwell clock and reseeds the RSSI: the peer left and came back.
        public var gapResetMilliseconds: Int64
        /// How long a peer stays in the snapshots after its last sighting.
        public var lingerMilliseconds: Int64

        /// knit-next's values unless told otherwise: 0.35, 8 s and 90 s.
        public init(rssiSmoothing: Double = 0.35, gapResetMilliseconds: Int64 = 8000, lingerMilliseconds: Int64 = 90_000) {
            self.rssiSmoothing = rssiSmoothing
            self.gapResetMilliseconds = gapResetMilliseconds
            self.lingerMilliseconds = lingerMilliseconds
        }
    }

    private struct Entry: Sendable {
        var advert: AdvertPayload
        var smoothedRssi: Double
        var firstSeenAt: Int64
        var lastSeenAt: Int64
    }

    private let configuration: Configuration
    private var entries: [NodeId: Entry] = [:]

    /// A tracker with knit-next's tunables unless told otherwise.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Records a sighting.
    public mutating func record(_ sighting: Sighting, now: Int64) {
        let nodeId = sighting.advert.nodeId
        guard var entry = entries[nodeId], now - entry.lastSeenAt <= configuration.gapResetMilliseconds else {
            // A new peer, or one back after a gap: restart the dwell clock and reseed the RSSI rather than
            // averaging across the gap.
            entries[nodeId] = Entry(advert: sighting.advert, smoothedRssi: Double(sighting.rssi), firstSeenAt: now, lastSeenAt: now)
            return
        }
        let weight = configuration.rssiSmoothing
        entry.smoothedRssi = weight * Double(sighting.rssi) + (1 - weight) * entry.smoothedRssi
        entry.lastSeenAt = now
        entry.advert = sighting.advert
        entries[nodeId] = entry
    }

    /// Every peer seen within the linger window, after dropping the rest.
    public mutating func snapshots(now: Int64) -> [Snapshot] {
        entries = entries.filter { now - $0.value.lastSeenAt <= configuration.lingerMilliseconds }
        return entries.values.map { entry in
            Snapshot(
                advert: entry.advert,
                smoothedRssi: entry.smoothedRssi,
                dwellMilliseconds: now - entry.firstSeenAt,
                lastSeenAgoMilliseconds: now - entry.lastSeenAt
            )
        }
    }

    /// The advert last seen from `nodeId`, for its PSM and flags, or `nil` if unknown.
    public func advert(of nodeId: NodeId) -> AdvertPayload? {
        entries[nodeId]?.advert
    }

    /// Whether `nodeId` was seen within the linger window: whether this node has sighted it, for the link
    /// layer's admission rule.
    public func isPresent(_ nodeId: NodeId, now: Int64) -> Bool {
        guard let entry = entries[nodeId] else {
            return false
        }
        return now - entry.lastSeenAt <= configuration.lingerMilliseconds
    }

    /// `nodeId`'s smoothed RSSI, or `nil` if unseen.
    public func smoothedRssi(of nodeId: NodeId) -> Double? {
        entries[nodeId]?.smoothedRssi
    }

    /// Forgets `nodeId`.
    public mutating func forget(_ nodeId: NodeId) {
        entries[nodeId] = nil
    }
}
