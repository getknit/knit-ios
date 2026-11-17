public import KnitWire

/// The links' and the blob plane's counts as the app reads them, moved out of ``Mesh``'s body as it grew.
extension Mesh {
    /// The peers linked now.
    public var neighbors: [Neighbor] { links.neighbors }

    /// The peers sighted now, linked or not.
    public var sightings: [PresenceTracker.Snapshot] { links.sightings() }

    /// Why frames were dropped so far.
    public var dropped: [DropReason: Int] { engine.dropped }

    /// What the presence keys' receive side did so far (ADR 2026-11.sv5t).
    public var presenceKeyCounts: PresenceKeyCounts { engine.presenceKeyCounts }

    /// Who is typing where now (``MeshEngine/typingNow``).
    public var typing: [String: [NodeId]] { engine.typingNow }

    /// What the router has done so far.
    public var routerCounters: Router.Counters { engine.routerCounters }

    /// What the engine and the link manager hold in memory, table by table.
    public var footprint: MeshFootprint {
        var tables = engine.footprint
        tables.channels = links.channelCount
        tables.crossings = links.crossingCount
        tables.arrivingFiles = links.arrivingFileKeys.count
        tables.queuedFiles = links.queuedFileCount
        return tables
    }

    /// What the links did with FILE records so far.
    public var files: FileCounts {
        links.fileCounts(rejected: engine.filesRejected)
    }

    /// What the blob holder query has done so far, both ends.
    public var blobs: BlobCounts { engine.blobCounts }
    /// How far each kept file streaming in has got (``LinkManager/arrivingFiles``); one past its END is stored this turn.
    public var arrivingFiles: [BlobHash: FileIntake.Reading] { links.arrivingFiles }
    /// Doorbells rung on peers' links, to wake a suspended iPhone (``LinkManager/rings``).
    public var rings: Int { links.rings }
    /// Rings of this node's own doorbell (``LinkManager/ringsHeard``).
    public var ringsHeard: Int { links.ringsHeard }
    /// Whether the radio is seeking peers (``LinkManager/isSeeking``).
    public var isSeeking: Bool { links.isSeeking }
    /// Wakes spent seeking (``LinkManager/seekWakes``).
    public var seekWakes: Int { links.seekWakes }
    /// Times seeking began (``LinkManager/seekSpells``).
    public var seekSpells: Int { links.seekSpells }
}
