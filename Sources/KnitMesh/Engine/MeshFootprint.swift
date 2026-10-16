/// How much the mesh holds in memory, table by table, so a long run can show that each one levels off. Custody
/// lives in the store and is counted there.
public struct MeshFootprint: Sendable, Equatable {
    /// Frame ids the router has seen: at most ``SeenSet/defaultCapacity``.
    public var seen: Int
    /// Relays waiting out their jitter.
    public var pendingRelays: Int
    /// DM ids purged by a receipt and tombstoned for a day.
    public var tombstones: Int
    /// Receipts remembered for a day, for a DM that lands after its own receipt: at most ``SeenSet/defaultCapacity``.
    public var earlyReceipts: Int
    /// Frames parked until their sender's key arrives.
    public var parked: Int
    /// Room and group ticks owed to authors who are not linked now: the owed entries, and the ids waiting in a batch or a
    /// ride hold (``AckSync/count``).
    public var owedTicks: Int
    /// Signed profiles kept to answer key requests.
    public var cachedProfiles: Int
    /// Senders whose key is still wanted.
    public var missingKeys: Int
    /// Channels open or opening.
    public var channels: Int
    /// The frame ids the open channels have carried.
    public var crossings: Int
    /// Blobs wanted and not yet held: at most ``BlobExchange/maxWanted``.
    public var wantedBlobs: Int
    /// Serves remembered, to hold off a second copy of one blob to one neighbour.
    public var servedBlobs: Int
    /// Files streaming in now, one per link at most.
    public var arrivingFiles: Int
    /// Files streaming out or waiting to, over every link.
    public var queuedFiles: Int

    /// A footprint of these counts.
    public init(
        seen: Int = 0,
        pendingRelays: Int = 0,
        tombstones: Int = 0,
        earlyReceipts: Int = 0,
        parked: Int = 0,
        owedTicks: Int = 0,
        cachedProfiles: Int = 0,
        missingKeys: Int = 0,
        channels: Int = 0,
        crossings: Int = 0,
        wantedBlobs: Int = 0,
        servedBlobs: Int = 0,
        arrivingFiles: Int = 0,
        queuedFiles: Int = 0
    ) {
        self.seen = seen
        self.pendingRelays = pendingRelays
        self.tombstones = tombstones
        self.earlyReceipts = earlyReceipts
        self.parked = parked
        self.owedTicks = owedTicks
        self.cachedProfiles = cachedProfiles
        self.missingKeys = missingKeys
        self.channels = channels
        self.crossings = crossings
        self.wantedBlobs = wantedBlobs
        self.servedBlobs = servedBlobs
        self.arrivingFiles = arrivingFiles
        self.queuedFiles = queuedFiles
    }
}
