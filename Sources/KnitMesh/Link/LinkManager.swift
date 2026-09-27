public import KnitWire

/// Owns every link, for every radio: who dials whom, who is admitted, the HELLO exchange, duplicates and stale
/// links (`BluetoothMeshTransport.kt`, with companion change A1's admission rule). The radios only move bytes.
///
/// **Who dials.** Whoever can see the other. The larger node id dials, as on Android, unless the peer cannot find
/// us: a peer that advertises service data without `FLAG_DIALS_GATT_PEERS` (Android 2.7) never reads a GATT
/// payload, so a radio that cannot advertise service data (an iPhone) dials it whatever the order.
///
/// **Who is admitted.** A dialer whose HELLO arrives within 5 s, unless we sighted it and our own rule says we
/// dial it: that is how a cross-dial is broken. A dialer we never sighted is admitted whatever the order, since
/// it may be an iPhone we cannot see. A second link from a linked peer is refused, unless we never sighted the
/// dialer: then it is the peer's fresh link replacing one that died on its side, and the old one is closed.
///
/// **Links are keyed by channel, not by node id.** On Android, closing a replaced link tore down its replacement
/// (`BluetoothMeshTransport.kt:787` and `:806`); here a channel's teardown touches only itself.
///
/// The manager is synchronous. It reads its clock, writes through its ``Radio``, and reports what the mesh
/// needs as ``Event``s from ``handle(_:)`` and ``advance()``.
public final class LinkManager: MeshTransport {
    /// The link layer's tunables.
    public struct Configuration: Sendable {
        /// How long a HELLO may take, each way (`ACCEPT_HELLO_TIMEOUT_MS`).
        public var helloTimeoutMilliseconds: Int64
        /// How long a dial may take to open (`CONNECT_TIMEOUT_MS`).
        public var connectTimeoutMilliseconds: Int64
        /// How long a custody change waits before it re-advertises, so a burst costs one advert
        /// (`CUE_READVERTISE_DEBOUNCE_MS`).
        public var advertDebounceMilliseconds: Int64
        /// The largest single write: Android caps its own at 8 KiB.
        public var maxWriteBytes: Int
        /// What a link scores for eviction while its peer has not once been sighted since the link came up (every
        /// inbound iPhone): the promotion floor, as A1 has it, not −127.
        public var unsightedLinkRssi: Double
        /// What a link scores once its peer, sighted during the link, has left presence: shed first, as on Android.
        public var absentLinkRssi: Double
        /// How old a held link must be before a second dial from the same unsighted peer may replace it
        /// (A1's `REPLACE_MIN_HOLD_MS`). The HELLO is unauthenticated, so this bounds how often a device that
        /// claims the peer's id can cut its link.
        public var replaceMinHoldMilliseconds: Int64
        /// How often a link's doorbell rings, at most, while frames go out on it. A ring wakes a suspended iPhone for
        /// about 9 s (iOS 27), so ringing at most every 5 s, and once more after the last frame of a burst, has every
        /// frame read within about 5 s of reaching the link. 0 never rings.
        public var ringIntervalMilliseconds: Int64
        /// Whom to link.
        public var promotion: PromotionPolicy.Configuration
        /// How long to wait after failures.
        public var backoff: ConnectBackoff.Configuration
        /// How sightings smooth and linger.
        public var presence: PresenceTracker.Configuration

        /// knit-next's values unless told otherwise.
        public init(
            helloTimeoutMilliseconds: Int64 = 5000,
            connectTimeoutMilliseconds: Int64 = 12_000,
            advertDebounceMilliseconds: Int64 = 1500,
            maxWriteBytes: Int = 8192,
            unsightedLinkRssi: Double = -90,
            absentLinkRssi: Double = -127,
            replaceMinHoldMilliseconds: Int64 = 30_000,
            ringIntervalMilliseconds: Int64 = 5000,
            promotion: PromotionPolicy.Configuration = PromotionPolicy.Configuration(),
            backoff: ConnectBackoff.Configuration = ConnectBackoff.Configuration(),
            presence: PresenceTracker.Configuration = PresenceTracker.Configuration()
        ) {
            self.helloTimeoutMilliseconds = helloTimeoutMilliseconds
            self.connectTimeoutMilliseconds = connectTimeoutMilliseconds
            self.advertDebounceMilliseconds = advertDebounceMilliseconds
            self.maxWriteBytes = maxWriteBytes
            self.unsightedLinkRssi = unsightedLinkRssi
            self.absentLinkRssi = absentLinkRssi
            self.replaceMinHoldMilliseconds = replaceMinHoldMilliseconds
            self.ringIntervalMilliseconds = ringIntervalMilliseconds
            self.promotion = promotion
            self.backoff = backoff
            self.presence = presence
        }
    }

    /// What the mesh needs to hear from the links.
    public enum Event: Sendable, Equatable {
        /// A link came up and its HELLO checked out.
        case up(Neighbor)
        /// A link went down.
        case down(NodeId)
        /// A frame arrived.
        case frame(InboundFrame)
        /// A custody digest arrived.
        case digest([String], from: NodeId)
    }

    enum Role: Equatable {
        /// We dialed, expecting this peer to answer.
        case dialer(NodeId)
        /// The peer dialed us.
        case responder
    }

    enum Stage: Equatable {
        /// A dial not yet open.
        case connecting
        /// Open, waiting for the other side's HELLO.
        case awaitingHello
        /// Registered to this peer: frames flow.
        case live(NodeId)
    }

    /// A registered link.
    struct LiveLink {
        let channel: ChannelID
        let neighbor: Neighbor
        let since: Int64
        /// Whether the peer has been sighted since the link came up; a dialer we dial always has.
        var sighted: Bool
    }

    struct Channel {
        let role: Role
        var stage: Stage
        var reader = LinkRecordReader()
        /// What the channel carried lately, for the warning if a record fails to parse.
        var trace = LinkTrace()
        /// When the dial or HELLO times out.
        var deadline: Int64?
    }

    struct Backoff {
        var streak: Int
        var nextAt: Int64
    }

    /// A link's doorbell: when it last rang, and when it rings again for frames written since.
    struct Doorbell {
        var rang: Int64
        var due: Int64?
    }

    /// This node.
    public let localId: NodeId
    let radio: any Radio
    let clock: any MeshClock
    let configuration: Configuration
    let log: any KnitLog
    var random: any RandomNumberGenerator

    var running = false
    var channels: [ChannelID: Channel] = [:]
    /// The registered links, one per peer, in the order they came up.
    var liveLinks: [LiveLink] = []
    var dialing: [NodeId: ChannelID] = [:]
    /// Peers refused both ways (``refuse(_:)``).
    var refused: Set<NodeId> = []
    var presence: PresenceTracker
    var addresses: [NodeId: RadioAddress] = [:]
    var backoffs: [NodeId: Backoff] = [:]
    var doorbells: [ChannelID: Doorbell] = [:]
    var crossings = LinkCrossings<ChannelID>()
    var psm: UInt16?
    var digestCue: UInt32 = 0
    var advertised: AdvertPayload?
    var advertDue: Int64?

    /// The live channel to `peer`, if linked.
    func liveChannel(to peer: NodeId) -> ChannelID? {
        liveLinks.first { $0.neighbor.nodeId == peer }?.channel
    }

    /// Channels in the order the radio opened them.
    static func inOrder(_ lhs: ChannelID, _ rhs: ChannelID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Frames dropped because they did not decode; the link stays up, as on Android.
    public internal(set) var undecodableFrames = 0
    /// FILE records discarded as they streamed by (avatars and attachments are out of the MVP).
    public internal(set) var discardedFileRecords = 0
    /// Rings asked of the radio, on every link since the manager was made. A radio that cannot ring, or a peer with no
    /// doorbell, makes nothing of one.
    public internal(set) var rings = 0
    /// Rings of this node's own doorbell.
    public internal(set) var ringsHeard = 0

    /// Channels open or opening.
    public var channelCount: Int { channels.count }

    /// The frame ids the open channels have carried, either way (``LinkCrossings``).
    public var crossingCount: Int { crossings.count }

    /// A link manager for `localId` over `radio`.
    public init(
        localId: NodeId,
        radio: any Radio,
        clock: any MeshClock,
        random: some RandomNumberGenerator,
        configuration: Configuration = Configuration(),
        log: any KnitLog = SilentLog()
    ) {
        self.localId = localId
        self.radio = radio
        self.clock = clock
        self.random = random
        self.configuration = configuration
        self.log = log
        presence = PresenceTracker(configuration: configuration.presence)
    }

    // MARK: MeshTransport

    public var neighbors: [Neighbor] {
        liveLinks.map(\.neighbor)
    }

    public func send(_ wire: WireEnvelope, to peer: NodeId?) {
        guard let record = LinkRecord(.frame, payload: wire.encoded).encoded else {
            log.log(.warning, "link dropped a frame too large for a record")
            return
        }
        let targets = peer.map { liveChannel(to: $0).map { [$0] } ?? [] } ?? liveLinks.map(\.channel)
        let key = FrameKey.ofSigned(wire)
        let now = clock.monotonicMilliseconds()
        let wakesThePeer = Self.rings(wire)
        for id in targets {
            // One write per link per frame, either way: the far end's seen set would drop the rest.
            if let key, !crossings.firstCrossing(link: id, key: key, now: now) {
                continue
            }
            write(record, on: id)
            if wakesThePeer {
                ringAfterFrame(on: id, now: now)
            }
        }
    }

    public func sendDigest(_ ids: [String], to peer: NodeId) {
        guard let id = liveChannel(to: peer), let record = LinkRecord(.digest, payload: LinkJSON.digestPayload(ids: ids)).encoded else {
            return
        }
        write(record, on: id)
    }

    // MARK: Lifecycle

    /// Starts the radio.
    public func start() {
        guard !running else {
            return
        }
        running = true
        radio.start()
    }

    /// Closes every link and stops the radio. Answers the links that went down.
    public func stop() -> [Event] {
        guard running else {
            return []
        }
        let events = forgetEverything()
        running = false
        radio.stop()
        return events
    }

    /// Custody changed; re-advertise its digest cue once the burst settles.
    public func updateDigestCue(_ cue: UInt32) {
        guard cue != digestCue else {
            return
        }
        digestCue = cue
        if advertDue == nil {
            advertDue = clock.monotonicMilliseconds() + configuration.advertDebounceMilliseconds
        }
    }

    /// Every sighted peer, for the UI's nearby count and diagnostics.
    public func sightings() -> [PresenceTracker.Snapshot] {
        presence.snapshots(now: clock.monotonicMilliseconds())
    }

    /// When ``advance()`` next has work, on the monotonic clock.
    public var nextDeadline: Int64? {
        let now = clock.monotonicMilliseconds()
        let backoffDue = backoffs.values.map(\.nextAt).filter { $0 > now }.min()
        let ringDue = doorbells.values.compactMap(\.due).min()
        return (channels.values.compactMap(\.deadline) + [advertDue, backoffDue, ringDue].compactMap(\.self)).min()
    }

    // MARK: Radio events

    /// Handles what the radio reported, and answers what the mesh needs to know.
    public func handle(_ event: RadioEvent) -> [Event] {
        let now = clock.monotonicMilliseconds()
        switch event {
        case .state(let state):
            log.log(.info, "link radio \(state)")
            return state == .on ? [] : forgetEverything()
        case .listening(let psm):
            self.psm = psm
            advertiseNow()
            return []
        case .sighted(let sighting):
            guard sighting.advert.nodeId != localId else {
                return []
            }
            presence.record(PresenceTracker.Sighting(advert: sighting.advert, rssi: sighting.rssi), now: now)
            addresses[sighting.advert.nodeId] = sighting.address
            for index in liveLinks.indices where liveLinks[index].neighbor.nodeId == sighting.advert.nodeId {
                liveLinks[index].sighted = true
            }
            return promote(now: now)
        case .connected(let id):
            connected(id, now: now)
            return []
        case .dialFailed(let id):
            return retire(id, backingOff: true, now: now) + promote(now: now)
        case .accepted(let id):
            channels[id] = Channel(role: .responder, stage: .awaitingHello, deadline: now + configuration.helloTimeoutMilliseconds)
            return []
        case .received(let id, let bytes):
            return receive(bytes, on: id, now: now)
        case .closed(let id):
            return retire(id, backingOff: true, now: now) + promote(now: now)
        case .rung:
            ringsHeard += 1
            return []
        }
    }

    /// Times out dials and HELLOs, re-advertises a settled cue, rings doorbells that are due, and retries peers whose
    /// backoff has run out.
    public func advance() -> [Event] {
        let now = clock.monotonicMilliseconds()
        var events: [Event] = []
        let expired = channels.filter { $0.value.deadline.map { now >= $0 } ?? false }.map(\.key).sorted(by: Self.inOrder)
        for id in expired {
            let dialed = channels[id]?.role != .responder
            log.log(.info, "link \(id) timed out")
            events += retire(id, backingOff: dialed, now: now)
        }
        if let due = advertDue, now >= due {
            advertDue = nil
            advertiseNow()
        }
        ringDue(now: now)
        return events + promote(now: now)
    }
}
