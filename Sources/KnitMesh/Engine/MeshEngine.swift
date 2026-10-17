public import KnitCrypto
import KnitStore
public import KnitWire

/// One node of the mesh: what it does with every frame, digest and link change, and what it sends of its own
/// (`MeshManager`, `InboundPipeline`, `ForwardSync`, `AckSync` and `KeyExchange` in knit-next).
///
/// The engine is synchronous and single-threaded. It reads time only from its ``MeshClock`` and randomness only
/// from its generator, writes only through its ``MeshTransport``, and keeps its timers as deadlines that
/// ``advance()`` fires. The driver (``Mesh``) owns it inside an actor; a test drives it by hand. Nothing here
/// throws: a frame that fails any check is dropped locally, counted in ``dropped``, and still relayed.
public final class MeshEngine {
    /// This node's keys.
    public let identity: IdentityKeys
    /// This node's ratchet prekeys, kept beside ``identity`` in its store, or `nil` for a node that keeps none, which then
    /// publishes none whatever the switch says (ADR 2026-10.5sk9).
    var prekeyRing: PrekeyRing?
    /// This node's key-independent device tag, published in its profile.
    let deviceTag: String?
    /// The repositories.
    public let stores: MeshStores
    /// The DM ratchet's sessions over ``stores``' ratchet store, and the floors it holds in memory (ADR 2026-10.5sk9). With
    /// the switch on, DM-form v2 and v3 frames to us open through it and its resets go out (phase P5a), and what we seal to
    /// a peer whose pinned profile carries `CAP_RATCHET` is sealed through it (phases P5b to P5e).
    let ratchet: RatchetSessions
    /// The group form's sessions over ``stores``' group store, and the floors it holds in memory (ADR 2026-10.5sk9). With the
    /// switch on, group-form frames open through it and the seeds our ratchet DMs carry are adopted into it (phase P6a2).
    let groupRatchet: GroupRatchetSessions
    /// The copies of the ratchet frames whose open's unit failed, opened again at the next sweep.
    var ratchetReplay = RatchetReplay()
    /// The seeds held back for a roster we do not hold yet, or a sender we hold as departed (phase P6a2).
    var pendingGroupKeys = PendingGroupKeys()
    /// The seed re-send and rejoin rekey floors our group sends hold in memory (phase P6b, ``GroupSendFloors``).
    var groupFloors = GroupSendFloors()
    /// What our reactions, sealed profile and init answers keep in memory (phase P5e, ``RatchetPresentationState``).
    var presentation = RatchetPresentationState()
    let transport: any MeshTransport
    let clock: any MeshClock
    let configuration: MeshConfiguration
    let log: any KnitLog
    var random: any RandomNumberGenerator

    var router: Router
    var custody = CustodySync()
    var pendingInbound = PendingInbound()
    var keyExchange: KeyExchange
    var blobExchange: BlobExchange
    /// The attachments the links were last told to keep as they stream in (``syncAcceptedFiles()``).
    var acceptedFiles: Set<BlobHash> = []
    /// The photo each neighbour has had from us whole, this run (``pushAvatar(to:)``).
    var avatarPushes: [NodeId: BlobHash] = [:]
    var ackSync = AckSync()
    /// What a sealed tick needs from us (ADR 2026-10.5sk9, phase P5d): seals made with the ratchet toward an author who can
    /// read one, which answer "cannot seal" by themselves with the switch off, so every tick ``ackSync`` owes is then
    /// today's cleartext one. A test may hand the ledger others.
    lazy var tickSeals: any TickSealing = RatchetTickSeals(engine: self)
    /// Who is typing where (``MeshEngine/handleTyping(_:)``).
    var typing = TypingBoard()
    /// When our last typing cue went to each thread, on the monotonic clock (``MeshEngine/noteTyping(in:)``).
    var typingCues: [ExactKey: Int64] = [:]
    var events: [MeshEvent] = []
    /// Our profile frame for the current publish stamp, signed once and reused (ADR 2026-09.qztx in knit-next).
    var signedProfile: SignedFrame?
    var timers: Timers?

    /// Why frames were dropped so far, by reason.
    public private(set) var dropped: [DropReason: Int] = [:]
    /// How our DMs were sealed so far, with the ratchet or v1 in its stead (``RatchetSealCounts``, phase P5b).
    public internal(set) var seals = RatchetSealCounts()
    /// How our receipts and ticks were sealed so far (phase P5d), all but the room ticks that rode, which ``ackSync``
    /// counts: ``receipts`` reads both.
    var receiptCounts = RatchetReceiptCounts()
    /// How the group form's receive side went so far (phase P6a2).
    public internal(set) var groupCounts = RatchetGroupCounts()
    /// Bumped whenever custody may have changed, so the driver knows to re-read ``digestCue``.
    public private(set) var custodyRevision = 0
    /// Whole files dropped here: their bytes did not match their hash, a pushed photo was not the one its pusher's
    /// profile names, or nothing wanted them.
    public internal(set) var filesRejected = 0

    struct Timers {
        var reoffer: Int64
        var sweep: Int64
        var heal: Int64
        /// When the ratchet's retention sweeps and the group custody replay are next due, read only with the switch on.
        var ratchetSweep: Int64
    }

    /// A node with `identity` and the prekeys it keeps, its repositories, and the transport, clock and randomness it runs
    /// on, whose ratchet draws its ephemerals, epoch keys and v2 IVs from `ratchetEngine`, and its group seeds and group-form
    /// IVs from `groupRatchetEngine`: the system's generator but for a vector, which passes fixed draws (A9's replays, and
    /// A10's emitted frames, phase P7b). Never the injected `random`, which a seed fixes (`crypto.md`, ADR 2026-10.5sk9's P4b
    /// amendment). A ring another identity signs is not this node's, and is left out.
    init(
        identity: IdentityKeys,
        prekeys: PrekeyRing?,
        deviceTag: String?,
        stores: MeshStores,
        transport: any MeshTransport,
        clock: any MeshClock,
        random: some RandomNumberGenerator,
        configuration: MeshConfiguration,
        log: any KnitLog,
        ratchetEngine: RatchetEngine,
        groupRatchetEngine: GroupRatchetEngine
    ) {
        self.identity = identity
        prekeyRing = prekeys.flatMap { $0.identity.bundle == identity.bundle ? $0 : nil }
        self.deviceTag = deviceTag
        self.stores = stores
        ratchet = RatchetSessions(identity: identity, store: stores.ratchet, transactor: stores.transactor, engine: ratchetEngine)
        // Its seeds and IVs come from `groupRatchetEngine`, as the DM engine's keys do, never the injected `random`.
        groupRatchet = GroupRatchetSessions(
            nodeId: identity.nodeId, store: stores.groupRatchet, transactor: stores.transactor, engine: groupRatchetEngine)
        self.transport = transport
        self.clock = clock
        self.random = random
        self.configuration = configuration
        self.log = log
        router = Router(configuration: configuration.router)
        blobExchange = BlobExchange(queriesHolders: configuration.queriesBlobHolders)
        keyExchange = KeyExchange { [peers = stores.peers] in peers.profileFrame(of: $0) }
    }

    /// This node's id.
    public var nodeId: NodeId { identity.nodeId }

    /// What the router has done so far.
    public var routerCounters: Router.Counters { router.counters }

    /// What the blob holder query has done so far (knit-next ADR 2026-10.6e5t).
    public var blobCounts: BlobCounts { blobExchange.counts }

    /// What the engine holds in memory. The link manager's two tables are the driver's to fill (``Mesh``).
    public var footprint: MeshFootprint {
        MeshFootprint(
            seen: router.seenCount,
            pendingRelays: router.pendingRelayCount,
            tombstones: custody.tombstoneCount,
            earlyReceipts: custody.earlyReceiptCount,
            parked: pendingInbound.count,
            owedTicks: ackSync.count,
            cachedProfiles: keyExchange.cachedProfileCount,
            missingKeys: keyExchange.missingIds.count,
            wantedBlobs: blobExchange.wanted.count,
            servedBlobs: blobExchange.servedCount
        )
    }

    /// Whether ``start()`` has run.
    public var isStarted: Bool { timers != nil }

    /// The advert's digest cue: the low 32 bits of the fold over every live carried id.
    public var digestCue: UInt32 {
        UInt32(truncatingIfNeeded: stores.custody.fingerprint(now: clock.wallMilliseconds()))
    }

    /// When ``advance()`` next has work, on the monotonic clock, or `nil` before ``start()``.
    public var nextDeadline: Int64? {
        guard let timers else {
            return nil
        }
        let blobs = [blobExchange.nextDeadline, blobExchange.parkPollAt]
        let ratchetSweep = configuration.ratchet ? timers.ratchetSweep : nil
        let ticks = ackSync.nextBatchDue
        return ([router.nextDeadline, timers.reoffer, timers.sweep, timers.heal, typing.nextDeadline, ticks, ratchetSweep] + blobs)
            .compactMap(\.self).min()
    }

    /// Starts the node (`MeshManager.seedOwnProfileCustody`): seeds our sealed profile's dedupe, brings our prekey in step
    /// with the ring and the switch, republishes our profile if its stamp is stale, puts it in custody, sweeps what
    /// expired while we were down, the ratchet's retention included, forgets deleted messages no carrier can still hold,
    /// opens again the ratchet DMs to us custody holds with no row, delivers group chats custody holds and our threads lack,
    /// and starts the timers. Idempotent.
    public func start() {
        guard !isStarted else {
            return
        }
        // Before the prekey's sync, so a rotation due now is a version the next heal still sends (phase P5e).
        seedSealedProfileVersions()
        // Before anything signs our profile, so the frame custody seeds already carries a due prekey
        // (`MeshManager.kt:2548-2551`).
        syncPrekey(atStart: true)
        republishIfStale()
        _ = ownProfile()
        sweep()
        // Before anything opens a frame, as Android's start sweeps the ratchet before its replay (`MeshManager.kt:2552`).
        sweepRatchet()
        stores.messages.pruneDeleted(before: clock.wallMilliseconds())
        // The DMs first: a seed whose unit failed before we stopped adopts here, and its instant replay opens that sender's
        // group frames, which the group replay would otherwise count as keyless and ask for again.
        replayCustodiedRatchetMessages()
        replayCustodiedGroupFrames(in: nil, from: nil)
        sweepUnreferencedBlobs()
        rewantMissingBlobs(sparing: [])
        let now = clock.monotonicMilliseconds()
        timers = Timers(
            reoffer: now + configuration.reofferMilliseconds,
            sweep: now + configuration.sweepMilliseconds,
            heal: now + configuration.healMilliseconds,
            ratchetSweep: now + RatchetSessions.sweepMilliseconds
        )
    }

    /// Hands over what happened since the last call, oldest first.
    public func drainEvents() -> [MeshEvent] {
        defer { events.removeAll() }
        return events
    }

    // MARK: Links

    /// A link to `neighbor` came up (`MeshManager.watchNeighbors`): push our profile and our photo, step the blobs we
    /// lack, send our digest, ask for the keys we lack, and send the ticks we owe it. A neighbour that links again holds
    /// no ask or query of ours, since one sent before may have died with the old link, so every fetch is open to it
    /// again first (`BlobExchange.linked`).
    public func linkUp(_ neighbor: Neighbor) {
        let peer = neighbor.nodeId
        pushProfile(to: peer)
        pushAvatar(to: peer)
        blobExchange.linked([peer])
        rewantMissingBlobs(sparing: Set(neighborIds))
        stepBlobs()
        transport.sendDigest(stores.custody.liveIds(now: clock.wallMilliseconds()), to: peer)
        askForMissingKeys(to: [peer])
        sendOwedTicks(to: peer)
        // A partition's merge: the seeds it never acknowledged, with the switch on (`MeshManager.kt:2521`, phase P6b).
        flushPendingGroupKeys(for: peer, force: false)
        events.append(.neighborsChanged(transport.neighbors))
        log.log(.info, "mesh link up \(peer)")
    }

    /// A link to `nodeId` went down. Every blob whose ask or hold stood on it takes its next step now, so the next holder
    /// is asked at once rather than at the next timer or tick (`BlobExchange.unlinked`, knit-next #140): an ask stands on
    /// a live link until its floor, never on one that is gone.
    public func linkDown(_ nodeId: NodeId) {
        stepBlobs(blobExchange.fetches(on: [nodeId]))
        events.append(.neighborsChanged(transport.neighbors))
        log.log(.info, "mesh link down \(nodeId)")
    }

    /// A frame arrived over a link (`MeshRouter.handleInbound`): deliver it if it is new, then relay it.
    public func receive(_ frame: InboundFrame) {
        let now = clock.monotonicMilliseconds()
        guard router.admit(frame, now: now) == .new else {
            return
        }
        deliver(frame)
        // The blob traffic is answered, never flooded, whatever its relay flag says. Android floods a request marked
        // `relay = true`, and every node it reached would serve the neighbour that handed it on; no build sends one
        // (ADR 2026-10.nh55). A holder query and its answer are as unsigned and as point to point.
        guard !frame.envelope.type.isUnsignedPointToPoint else {
            return
        }
        perform(router.relay(frame, neighbors: neighborIds, jitter: drawJitter(), now: now))
    }

    /// A neighbour's custody digest arrived (`ForwardSync.onDigest`): serve every live frame it lacks, each sender's
    /// key ahead of a backlog the neighbour could not otherwise verify.
    public func receiveDigest(_ ids: [String], from neighbor: NodeId) {
        // When each one lands shows what a slow link spends on them: every 60 s, the whole live id set each way.
        log.log(.debug, "mesh digest from \(neighbor): \(ids.count) ids")
        let reply = custody.missing(from: ids, for: neighbor, in: stores.custody, now: clock.wallMilliseconds())
        for sender in reply.keysAhead {
            // Point to point, as a key request's answer goes, so it is never flooded (knit-next ADR 2026-09.7bu7).
            if let key = keyExchange.serveKey(sender) {
                transport.send(key, to: neighbor)
            }
        }
        for wire in reply.frames {
            transport.send(wire, to: neighbor)
        }
    }

    // MARK: Time

    /// Fires every relay and timer that is due.
    public func advance() {
        let now = clock.monotonicMilliseconds()
        perform(router.fireDue(now: now, neighbors: neighborIds))
        guard var due = timers else {
            return
        }
        stepDueBlobs(now: now)
        pollParkedAsks(now: now)
        lapseTyping(now: now)
        flushDueTickBatches(now: now)
        if now >= due.reoffer {
            reoffer()
            due.reoffer = now + configuration.reofferMilliseconds
        }
        if now >= due.sweep {
            sweep()
            due.sweep = now + configuration.sweepMilliseconds
        }
        if now >= due.heal {
            heal()
            due.heal = now + configuration.healMilliseconds
        }
        if configuration.ratchet, now >= due.ratchetSweep {
            sweepRatchet()
            // The net under the instant replays (`replayUndeliveredGroupCustody`, `MeshManager.kt:971`), once an hour as
            // Android's heal runs it (`GROUP_REPLAY_MS`, `:3511`), after the sweeps as there.
            replayCustodiedGroupFrames(in: nil, from: nil)
            due.ratchetSweep = now + RatchetSessions.sweepMilliseconds
        }
        timers = due
    }

    // MARK: Shared helpers

    var neighborIds: [NodeId] { transport.neighbors.map(\.nodeId) }

    func perform(_ sends: [Send]) {
        for send in sends {
            transport.send(send.wire, to: send.to)
        }
    }

    func drop(_ reason: DropReason, _ envelope: RelayEnvelope) {
        dropped[reason, default: 0] += 1
        log.log(.debug, "mesh drop \(envelope.type.rawValue) \(envelope.id) from \(envelope.senderId): \(reason)")
    }

    func noteCustodyChanged() {
        custodyRevision += 1
    }

    /// A relay's jitter, uniform in `0..<jitterWindowMilliseconds`.
    func drawJitter() -> Int64 {
        let window = UInt64(max(1, configuration.router.jitterWindowMilliseconds))
        return Int64(random.next(upperBound: window))
    }

    /// A fresh frame id from the injected generator.
    func newFrameId() -> String {
        FrameId.generate(using: &random)
    }

    /// A sender-supplied clock bounded to five minutes past ours before it becomes a local watermark
    /// (`InboundPipeline.clampFuture`), so one far-future stamp cannot outrank every honest one after it.
    func clampFuture(_ stamp: Int64) -> Int64 {
        min(stamp, clock.wallMilliseconds() + WireProtocol.maxFutureSkewMilliseconds)
    }

    /// Signs `envelope` into a ``WireEnvelope``, or `nil` if the key refuses, which Ed25519 does not do in
    /// practice: a frame that cannot be signed is simply not sent.
    func sign(_ envelope: RelayEnvelope, relay: Bool) -> WireEnvelope? {
        let signed = envelope.encoded
        return (try? identity.signature(for: signed)).map { WireEnvelope(relay: relay, sig: $0, signed: signed) }
    }
}

extension MeshEngine {
    /// A node with `identity` and the prekeys it keeps, its repositories, and the transport, clock and randomness it runs
    /// on. A ring another identity signs is not this node's, and is left out.
    public convenience init(
        identity: IdentityKeys,
        prekeys: PrekeyRing? = nil,
        deviceTag: String?,
        stores: MeshStores,
        transport: any MeshTransport,
        clock: any MeshClock,
        random: some RandomNumberGenerator,
        configuration: MeshConfiguration = MeshConfiguration(),
        log: any KnitLog = SilentLog()
    ) {
        self.init(
            identity: identity,
            prekeys: prekeys,
            deviceTag: deviceTag,
            stores: stores,
            transport: transport,
            clock: clock,
            random: random,
            configuration: configuration,
            log: log,
            ratchetEngine: RatchetEngine(),
            groupRatchetEngine: GroupRatchetEngine()
        )
    }
}
