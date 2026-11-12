public import KnitCrypto
public import KnitStore
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
/// dialer: then it is the peer's fresh link replacing one that died on its side, and the old one is closed. A dialer
/// whose proven link the radio closed in the last 30 s, proving itself again, is admitted though we would dial it, while
/// no dial of ours to it is open (``RelinkWindow``).
///
/// **Who is who.** When both HELLOs carry ``Capabilities/linkProof``, each side proves the id its HELLO claims before the
/// link registers, and a proven link displaces unproven ones claiming its id; an id known to prove itself is refused
/// unproven (``LinkClaims``, `LinkManager+LinkProof.swift`). A build from before the proof links unproven, as before.
///
/// **Links are keyed by channel, not by node id.** On Android, closing a replaced link tore down its replacement
/// (`BluetoothMeshTransport.kt:787` and `:806`); here a channel's teardown touches only itself.
///
/// The manager is synchronous. It reads its clock, writes through its ``Radio``, and reports what the mesh
/// needs as ``Event``s from ``handle(_:)`` and ``advance()``.
public final class LinkManager: MeshTransport {
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
        /// A whole file arrived, its hash not yet checked.
        case file(InboundFile)
        /// A file streaming in has got this far: on every chunk that brings ``windowedProgressEveryBytes``, at least
        /// every ``windowedProgressEveryMilliseconds``, and once more after chunks no report carried (knit-next ADRs
        /// 2026-10.nsr7 and 2026-10.5buf). A stall reports nothing.
        case fileProgress(FileProgress)
        /// A file we streamed left the radio whole, its END included (``sendFile(_:to:)``).
        case fileSent(BlobHash, to: NodeId)
        /// An ATTACHMENT streaming in from a neighbour, kept at its header under a photo-only want's ceiling, passed it,
        /// or its header declared more (``FileIntake/Event/overLimit(_:)``, ``IntakeCeiling``): nothing of it is kept,
        /// and the rest of its stream is read past. The engine passes over that neighbour for a profile photo
        /// (``MeshEngine/fileOverLimit(_:from:)``). A pushed AVATAR, or an attachment under Android's ceiling, cut off
        /// the same way raises nothing (`refuseOver`, knit-next `FileIntake.kt:388-398` at `a0b52f865`).
        case fileOverLimit(BlobHash, from: NodeId)
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
    /// Signs our side of a link's proof with this node's identity key, the one ``localId`` derives from (``LinkProof``), or
    /// answers `nil` when the key will not sign: a failed proof, with nothing written. No valid key fails, so only a test
    /// sets this.
    var signProof: (LinkProof.Role, [UInt8], [UInt8]) -> [UInt8]?
    /// Who must prove the id a HELLO claims, and the proofs' counts (``LinkClaims``).
    var claims: LinkClaims
    /// The links ``peerProvesItself(_:)`` closed, handed over ahead of whatever the next public entry answers.
    var deferredDowns: [Event] = []
    /// knit-peer's impostor, a trial's switch the app never sets (``Impostor``).
    public var impostor = Impostor()
    let radio: any Radio
    let clock: any MeshClock
    let configuration: Configuration
    let log: any KnitLog
    var random: any RandomNumberGenerator
    /// The kept prefixes of attachments a cut link left (knit-ios #2): the one store the engine asks with and resumes from.
    let partials: any PartialBlobStore

    var running = false
    var channels: [ChannelID: Channel] = [:]
    /// The registered links, one per peer, in the order they came up.
    var liveLinks: [LiveLink] = []
    /// Dials in flight, by the key each is booked under (``DialKey``).
    var dialing: [DialKey: ChannelID] = [:]
    /// Peers refused both ways (``refuse(_:)``).
    var refused: Set<NodeId> = []
    var presence: PresenceTracker
    /// Where each sighting was last heard, by the key it is kept under, pruned with presence.
    var addresses: [SightingKey: RadioAddress] = [:]
    /// Backoffs by what they were booked under: a peer's own key, a dial key, an address or a handle streak.
    var backoffs: [DialKey: Backoff] = [:]
    /// Resolves blinded adverts (``AdvertAliases``), keyed by the links its claims and hints came on.
    var aliases: AdvertAliases<ChannelID>
    /// The handles of the tags heard (``FormKeys``).
    var formKeys = FormKeys()
    /// The tags and addresses whose tag dial proved another id than a key names (``ReplayMarks``).
    var replayMarks = ReplayMarks()
    /// Bounds a contact's key churn between ``listPresenceKeys(_:)`` and the resolver (``KeyChurnLimiter``).
    var keyLimiter = KeyChurnLimiter()
    /// The keys a held link's refused dials earned (``HeldStreaks``).
    var heldStreaks = HeldStreaks<ChannelID>()
    /// Each live proven link we dialed at a tag, by the dial key it was dialed under (``DialKeys/heldDial(_:proven:)``).
    var heldDials: [ChannelID: DialKey] = [:]
    /// Each tag dial key whose dial proved a refused id, and that id (``refusedTagDial(_:_:_:now:)``): promotion passes the
    /// tag at that address over while the id stays refused. Pruned with presence, and with its handle.
    var refusedDials: [DialKey: NodeId] = [:]
    /// The newest `TAG_NEXT` each link sent in the read being handled, taken once the read's records drain.
    var tagNextHeld: [ChannelID: NodeId] = [:]
    /// The reader's own counts, beside ``AdvertAliases/counters``.
    var blindCounts = BlindCounts()
    /// The blinded advert's writer (`LinkManager+Writer.swift`).
    lazy var blindWriter = BlindWriter(localId: localId, switchOn: configuration.blindSwitchOn)
    /// The ids the radio closed a proven link to lately, which may redial us out of order once (``RelinkWindow``).
    lazy var relinkWindow = RelinkWindow(lengthMilliseconds: configuration.relinkWindowMilliseconds)
    var doorbells: [ChannelID: Doorbell] = [:]
    /// Each live link's incoming file, kept apart from ``channels`` so that reading a channel never copies a file's
    /// bytes.
    var intakes: [ChannelID: FileIntake] = [:]
    /// When each live link's incoming file began, and when it was last reported back to its sender (``Event/fileProgress(_:)``).
    var arrivalClocks: [ChannelID: ArrivalClock] = [:]
    /// Each live link's outgoing files: the one streaming and those waiting behind it.
    var feeds: [ChannelID: FileFeed] = [:]
    /// The attachments the engine wants kept when they stream in (``acceptFiles(_:resumable:photoOnly:)``).
    var fileKeys = AcceptedFileKeys()
    /// Whole files past their END that the engine has not taken yet (``fileTaken(from:hash:)``), still on their way.
    var landingFiles: Set<LandingFile> = []
    /// Files that finished streaming outside ``handle(_:)`` and ``advance()``, handed over by the next of either.
    var finishedFiles: [Event] = []
    /// Whether a feed's reading moved since ``takeFeedsChanged()`` last ran (``noteFeedsChanged()``).
    var feedsChanged = false
    var crossings = LinkCrossings<ChannelID>()
    /// Inbound digests each peer may hand over: a burst of 2, then one per 30 s (ADR 2026-10.f5zs). Each admitted digest
    /// makes the engine serve every live frame it omits, so a neighbour looping empty digests would have us re-serve our
    /// whole custody. Keyed by node id, not channel, and never cleared on `retire` or `register`, so a relink under the
    /// same id gets no fresh burst; its own LRU of 64 bounds it. An honest peer sends one at link-up and one every 60 s
    /// (`MeshManager.kt:3025-3048` at `e63f15f4`), and a link-up then a relink inside 30 s still finds a token.
    var digestBudget = IngressBudget<NodeId>(burst: digestBurst, perMinute: digestsPerMinute)
    /// The digests a peer may send at once: its link-up digest and one more, a relink's (ADR 2026-10.f5zs).
    static let digestBurst = 2
    /// The digests a peer may sustain, one per 30 s: twice the honest 60 s re-offer (ADR 2026-10.f5zs).
    static let digestsPerMinute = 2
    var digestCue: UInt32 = 0
    var advertised: AdvertPayload?
    var advertDue: Int64?
    /// Whether the app is in the background, where iOS may suspend it (``setInBackground(_:)``).
    var inBackground = false
    /// Each live link's write progress, polled to close one whose writes have stalled (ADR 2026-10.f5zs). Its own
    /// field, never a channel's `deadline` or `putOff`: a link's HELLO may have spent the put-off, and the deadline's
    /// expiry logs `timed out`, which the harness reads as a missed HELLO.
    var stallWatch = WriteStallWatch(configuration: WriteStallWatch.Configuration(lateMilliseconds: suspendedLatenessMilliseconds))
    /// The wakes the current spell of seeking has spent.
    var spell = SeekSpell()

    /// Frames dropped because they did not decode; the link stays up, as on Android.
    public internal(set) var undecodableFrames = 0
    /// Digests dropped because their peer was over its budget (``digestBudget``, ADR 2026-10.f5zs); the link stays up.
    public internal(set) var refusedDigests = 0
    /// Whole files that arrived, their hashes not yet checked.
    public internal(set) var filesReceived = 0
    /// Files dropped as they streamed in: unwanted, malformed, too large, or cut off by another header.
    public internal(set) var filesRefused = 0
    /// Files that left the radio whole.
    public internal(set) var filesSent = 0
    /// Of those, the ones that streamed only the tail an asker lacked (`MeshMetrics.onFileResumedOut`, knit-next ADR
    /// 2026-10.wtyc).
    public internal(set) var filesResumedOut = 0
    /// Files whose stream was spliced onto a prefix we kept, counted at their header (`MeshMetrics.onFileResumedIn`).
    public internal(set) var filesResumedIn = 0
    /// Rings asked of the radio, on every link since the manager was made. A radio that cannot ring, or a peer with no
    /// doorbell, makes nothing of one.
    public internal(set) var rings = 0
    /// Rings of this node's own doorbell.
    public internal(set) var ringsHeard = 0
    /// Whether the radio is seeking peers (``Radio/seekPeers(_:)``): in the background, with no link and wakes left.
    public internal(set) var isSeeking = false
    /// Wakes spent seeking, since the manager was made.
    public internal(set) var seekWakes = 0
    /// Times seeking began, since the manager was made.
    public internal(set) var seekSpells = 0

    /// Channels open or opening.
    public var channelCount: Int { channels.count }

    /// The frame ids the open channels have carried, either way (``LinkCrossings``).
    public var crossingCount: Int { crossings.count }

    /// A link manager for `identity`'s node over `radio`, keeping cut attachments' prefixes in `partials`. Whether a peer's
    /// stored profile carries ``Capabilities/linkProof`` comes from `profileCarriesProof` (``LinkClaims``).
    public init(
        identity: IdentityKeys,
        radio: any Radio,
        clock: any MeshClock,
        random: some RandomNumberGenerator,
        configuration: Configuration = Configuration(),
        log: any KnitLog = SilentLog(),
        partials: any PartialBlobStore = MemoryPartialBlobStore(),
        profileCarriesProof: @escaping (NodeId) -> Bool = { _ in false }
    ) {
        localId = identity.nodeId
        signProof = { signer, dialerHello, responderHello in
            try? LinkProof.payload(keys: identity, signer: signer, dialerHello: dialerHello, responderHello: responderHello)
        }
        claims = LinkClaims(profileCarriesProof: profileCarriesProof)
        self.radio = radio
        self.clock = clock
        self.random = random
        self.configuration = configuration
        self.log = log
        self.partials = partials
        presence = PresenceTracker(configuration: configuration.presence)
        aliases = AdvertAliases(now: { [clock] in clock.monotonicMilliseconds() }, wall: { [clock] in clock.wallMilliseconds() })
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

    /// Hands the radio the whole record, not slices of it, so it can put a newer digest in the place of one still
    /// waiting on a busy link (``Radio/writeDigest(_:to:)``).
    public func sendDigest(_ ids: [String], to peer: NodeId) {
        guard let id = liveChannel(to: peer), let record = LinkRecord(.digest, payload: LinkJSON.digestPayload(ids: ids)).encoded else {
            return
        }
        radio.writeDigest(record, to: id)
    }

    // MARK: Lifecycle

    /// Starts the radio.
    public func start() {
        guard !running else {
            return
        }
        running = true
        blindWriter.sessionHadKey = false
        radio.start()
        // Nothing is linked at a start, so the promotion that seeking runs has no link to evict.
        _ = reconsiderSeeking(now: clock.monotonicMilliseconds())
    }

    /// Closes every link and stops the radio. Answers the links that went down.
    public func stop() -> [Event] {
        guard running else {
            return []
        }
        let events = takeDeferredDowns() + forgetEverything(keepingCuts: false)
        running = false
        radio.stop()
        return events + reconsiderSeeking(now: clock.monotonicMilliseconds())
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

    /// When ``advance()`` next has work, on the monotonic clock: a dial, HELLO or PROOF timing out, the advert, a doorbell,
    /// a backoff running out, a dwell or a head start ending between a peer's adverts, a file's next chunk, a trailing
    /// report, the next look at the live links' writes (``WriteStallWatch``), the blinded advert's reader and writer
    /// (``blindDue(now:)``), or now, while links closed outside an entry wait to be handed over (``peerProvesItself(_:)``).
    public var nextDeadline: Int64? {
        let now = clock.monotonicMilliseconds()
        guard deferredDowns.isEmpty else {
            return now
        }
        let backoffDue = backoffs.values.map(\.nextAt).filter { $0 > now }.min()
        let ringDue = doorbells.values.compactMap(\.due).min()
        let fileDue = finishedFiles.isEmpty ? feeds.values.compactMap(\.due).min() : now
        let due = [advertDue, backoffDue, ringDue, dwellDue(now: now), fileDue, trailingReportDue, stallWatch.due, blindDue(now: now)]
            .compactMap(\.self)
        return (channels.values.compactMap(\.deadline) + due).min()
    }

    // MARK: Radio events

    /// Handles what the radio reported, and answers what the mesh needs to know.
    public func handle(_ event: RadioEvent) -> [Event] {
        let now = clock.monotonicMilliseconds()
        // A wake's first event may beat the overdue timer: the late check's re-stamps come first, or a held link reads quiet.
        let late = stallWatch.isLate(now: now) ? checkWriteStalls(now: now) : []
        return takeDeferredDowns() + late + respond(to: event, now: now) + reconsiderSeeking(now: now) + takeFinishedFiles()
    }

    private func respond(to event: RadioEvent, now: Int64) -> [Event] {
        switch event {
        case .state(let state):
            log.log(.info, "link radio \(state)")
            guard state == .on else {
                // Off from Settings or Control Centre, resetting, unauthorized, or a BlueZ power cycle: the session goes
                // on, so a cut attachment's bytes are kept for the ask that follows the radio back.
                return forgetEverything(keepingCuts: true)
            }
            // Bluetooth coming back on is a fresh start, for the wakes too.
            spell = SeekSpell()
            return []
        case .listening(let psm):
            listening(on: psm)
            return []
        case .sighted(let sighting):
            guard let key = sightingKey(of: sighting) else {
                return []
            }
            presence.record(PresenceTracker.Sighting(advert: sighting.advert, rssi: sighting.rssi), as: key, now: now)
            addresses[key] = sighting.address
            for index in liveLinks.indices where SightingKey.node(liveLinks[index].neighbor.nodeId) == key {
                liveLinks[index].sighted = true
                liveLinks[index].heardServiceData = liveLinks[index].heardServiceData || Self.isServiceData(sighting.advert)
            }
            if isSeeking {
                countSeekWake(now: now)
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
            radioClosed(id, now: now)
            return retire(id, backingOff: true, now: now) + promote(now: now)
        case .rung:
            return heardRing(now: now)
        case .wroteFileRecord(let id):
            return fileRecordWritten(on: id, now: now)
        }
    }

    /// Times out dials, HELLOs and PROOFs, re-advertises a settled cue, rings doorbells that are due, feeds files, sends the
    /// trailing reports that are due, and dials peers whose backoff has run out or whose dwell has just ended.
    public func advance() -> [Event] {
        let now = clock.monotonicMilliseconds()
        var events = takeDeferredDowns()
        let expired = channels.filter { $0.value.deadline.map { now >= $0 } ?? false }.map(\.key).sorted(by: Self.inOrder)
        for id in expired {
            if putOffLateDeadline(of: id, now: now) {
                continue
            }
            let dialed = channels[id]?.role != .responder
            if let channel = channels[id], case .awaitingProof(let pending) = channel.stage {
                // Never `timed out`, which the harness reads as a missed HELLO.
                proofFailed(on: id, for: pending.peer, why: "timeout")
            } else {
                log.log(.info, "link \(id) timed out")
            }
            events += retire(id, backingOff: dialed, now: now)
        }
        if let due = advertDue, now >= due {
            advertDue = nil
            advertiseNow()
        }
        ringDue(now: now)
        advanceBlind(now: now)
        events += checkWriteStalls(now: now)
        events += reportTrailing(now: now)
        events += feedDueFiles(now: now)
        return events + promote(now: now) + reconsiderSeeking(now: now)
    }
}
