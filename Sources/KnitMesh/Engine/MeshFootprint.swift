/// How much the mesh holds in memory, table by table, so a long run can show that each one levels off. Custody
/// lives in the store and is counted there.
public struct MeshFootprint: Sendable, Equatable {
    /// Frame ids the router has seen: at most ``SeenSet/defaultCapacity``.
    public var seen: Int
    /// Relays waiting out their jitter.
    public var pendingRelays: Int
    /// DM ids purged by a receipt and tombstoned for a day.
    public var tombstones: Int
    /// Frames parked until their sender's key arrives.
    public var parked: Int
    /// Room ticks owed to authors who are not linked now.
    public var owedTicks: Int
    /// Signed profiles kept to answer key requests.
    public var cachedProfiles: Int
    /// Senders whose key is still wanted.
    public var missingKeys: Int
    /// Channels open or opening.
    public var channels: Int
    /// The frame ids the open channels have carried.
    public var crossings: Int

    /// A footprint of these counts.
    public init(
        seen: Int = 0,
        pendingRelays: Int = 0,
        tombstones: Int = 0,
        parked: Int = 0,
        owedTicks: Int = 0,
        cachedProfiles: Int = 0,
        missingKeys: Int = 0,
        channels: Int = 0,
        crossings: Int = 0
    ) {
        self.seen = seen
        self.pendingRelays = pendingRelays
        self.tombstones = tombstones
        self.parked = parked
        self.owedTicks = owedTicks
        self.cachedProfiles = cachedProfiles
        self.missingKeys = missingKeys
        self.channels = channels
        self.crossings = crossings
    }
}
