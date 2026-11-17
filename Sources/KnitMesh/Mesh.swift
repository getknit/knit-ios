public import KnitCrypto
public import KnitStore
public import KnitWire

/// The mesh on a real radio (`MeshManager.start` and `MeshService` in knit-next): one actor that owns the
/// ``MeshEngine`` and the ``LinkManager``, feeds them what the ``Radio`` reports, fires their timers when they
/// fall due, and takes the app's sends.
///
/// Both state machines are synchronous, so every radio event, timer and send runs to completion inside the actor,
/// one at a time, and a test can drive the same code without it.
///
/// The mesh can stop and start again, as Settings' Stop and Start do. It listens to the radio from the first
/// start on, since a radio's stream ends for good when its listener is cancelled; while stopped it hears only the
/// radio's state.
public actor Mesh {
    /// What the mesh did that the app should know about.
    nonisolated public let events: AsyncStream<MeshEvent>
    /// This node's id.
    nonisolated public let nodeId: NodeId

    /// The engine, reached by this actor's extensions in other files (`Mesh+Ratchet.swift`).
    let engine: MeshEngine
    /// The links, reached by this actor's extensions in other files (`Mesh+LinkProof.swift`).
    let links: LinkManager
    /// The kept prefixes of cut attachments, which the links and the engine share (knit-ios #2), purged at every start and
    /// stop: they belong to one session's transfers (`MeshManager.kt:997-998`).
    private let partials: any PartialBlobStore
    private let radio: any Radio
    private let clock: any MeshClock
    private let continuation: AsyncStream<MeshEvent>.Continuation
    private var eventLoop: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var scheduled: Int64?
    private var advertisedRevision = -1
    /// What says the wall clock was set, and its observer while running (``wallClockChanged()``).
    var clockWatch = ClockWatch()
    /// The spool plane's synchronous core (ADR 2026-11.adrq, P4a), beside the links: its relays' heal loops and connections,
    /// the scope table and the shared seal cache. It carries no relay until P4b's sockets add one.
    var spool: SpoolPlane

    /// Whether the mesh is running: started, and not stopped since.
    public private(set) var isRunning = false
    /// What the radio last said of its state, or `nil` before it has said anything.
    public private(set) var radioState: RadioState?

    /// A mesh node for `identity`, with the ratchet prekeys it keeps beside it, or none, on `radio`, keeping cut
    /// attachments' prefixes in `partials`, or in memory.
    public init(
        identity: IdentityKeys,
        prekeys: PrekeyRing? = nil,
        deviceTag: String?,
        stores: MeshStores,
        radio: any Radio,
        clock: any MeshClock,
        random: some RandomNumberGenerator & Sendable,
        configuration: MeshConfiguration = MeshConfiguration(),
        linkConfiguration: LinkManager.Configuration = LinkManager.Configuration(),
        log: any KnitLog = SilentLog(),
        partials: (any PartialBlobStore)? = nil
    ) {
        // One store for both, so the engine asks with what the links keep. In memory unless the app hands one on disk.
        let shared = partials ?? MemoryPartialBlobStore { line in log.log(.info, "mesh \(line)") }
        self.partials = shared
        let linkManager = LinkManager(
            identity: identity,
            radio: radio,
            clock: clock,
            random: random,
            configuration: linkConfiguration,
            log: log,
            partials: shared,
            profileCarriesProof: Self.profileCarriesProof(in: stores.peers)
        )
        links = linkManager
        engine = MeshEngine(
            identity: identity,
            prekeys: prekeys,
            deviceTag: deviceTag,
            stores: stores,
            transport: linkManager,
            clock: clock,
            random: random,
            configuration: configuration,
            log: log,
            ratchetEngine: RatchetEngine(),
            groupRatchetEngine: GroupRatchetEngine(),
            partials: shared
        )
        self.radio = radio
        self.clock = clock
        nodeId = identity.nodeId
        spool = SpoolPlane(me: identity.nodeId)
        (events, continuation) = AsyncStream<MeshEvent>.makeStream()
    }

    deinit {
        eventLoop?.cancel()
        timer?.cancel()
        continuation.finish()
    }

    /// Starts the node and its radio, and begins listening to it.
    public func start() {
        guard !isRunning else {
            return
        }
        isRunning = true
        // Before anything asks or links: a prefix from before is no transfer of this session's.
        partials.purge()
        // A new session of the presence keys: its first listing deletes every non-contact's keys (ADR 2026-11.sv5t).
        engine.startPresenceKeySession()
        engine.start()
        links.start()
        if eventLoop == nil {
            eventLoop = Task { [weak self, events = radio.events] in
                for await event in events {
                    await self?.process(event)
                }
            }
        }
        observeClock()
        settle()
    }

    /// Stops the radio and closes every link. What the app sends meanwhile waits in custody for the next start.
    public func stop() {
        guard isRunning else {
            return
        }
        isRunning = false
        timer?.cancel()
        timer = nil
        scheduled = nil
        forgetClock()
        apply(links.stop())
        partials.purge()
        engine.forgetTyping()
        publish()
    }

    /// Handles one radio event: what the radio's stream delivers, one at a time. While stopped, only a change of
    /// state is heard.
    ///
    /// Every delivery is reported consumed once the link manager has taken it, and while stopped too, so the radio
    /// reads the channel on (``Radio/consumed(_:on:)``, ADR 2026-10.f5zs). A stopped mesh that kept quiet would leave
    /// every channel paused at its credit.
    public func process(_ event: RadioEvent) {
        defer {
            if case .received(let channel, let bytes) = event {
                radio.consumed(bytes.count, on: channel)
            }
        }
        if case .state(let state) = event, state != radioState {
            radioState = state
            continuation.yield(.radioChanged(state))
        }
        guard isRunning else {
            return
        }
        apply(links.handle(event))
        settle()
    }

    /// Fires whatever timers are due now; the timer task calls this when the next deadline arrives.
    public func fireDueTimers() {
        apply(links.advance())
        engine.advance()
        spool.tick(engine: engine)
        settle()
    }

    // MARK: The app's side

    /// `picked` as the picture this phone already holds it as, or `nil` (``MeshEngine/heldPhoto(picked:)``).
    public func heldPhoto(picked: [UInt8]) -> OutgoingPhoto? {
        engine.heldPhoto(picked: picked)
    }

    /// Accepts a message request, and fetches its photos (``MeshEngine/accept(_:)``).
    public func accept(_ conversationId: String) {
        engine.accept(conversationId)
        spool.markTableDirty()
        settle()
    }

    /// Makes a group with `others`, or opens the one they already share (``MeshEngine/createGroup(with:)``).
    @discardableResult
    public func createGroup(with others: [NodeId]) -> GroupRecord? {
        defer { publish() }
        return engine.createGroup(with: others)
    }

    /// Renames a group and floods the change (``MeshEngine/renameGroup(_:to:)``).
    @discardableResult
    public func renameGroup(_ groupId: String, to name: String) -> GroupRecord? {
        defer { settle() }
        return engine.renameGroup(groupId, to: name)
    }

    /// Leaves a group, telling its members (``MeshEngine/leaveGroup(_:)``).
    @discardableResult
    public func leaveGroup(_ groupId: String) -> Bool {
        defer { settle() }
        return engine.leaveGroup(groupId)
    }

    /// Deletes one message from this iPhone, sending nothing (``MeshEngine/deleteMessage(_:)``, ADR 2026-10.u7cq).
    @discardableResult
    public func deleteMessage(_ id: String) -> Bool {
        defer { settle() }
        return engine.deleteMessage(id)
    }

    /// Deletes a whole thread from this iPhone, sending nothing (``MeshEngine/deleteChat(_:)``, ADR 2026-10.u7cq).
    @discardableResult
    public func deleteChat(_ conversationId: String) -> Bool {
        defer {
            spool.markTableDirty()
            settle()
        }
        return engine.deleteChat(conversationId)
    }

    /// Reacts to a message, or takes our reaction back, and floods it (``MeshEngine/react(to:with:)``, ADR 2026-10.ehe6).
    @discardableResult
    public func react(to messageId: String, with emoji: String) -> ReactionRecord? {
        defer { settle() }
        return engine.react(to: messageId, with: emoji)
    }

    /// Tells `thread` that we are typing, at most once a throttle's interval (``MeshEngine/noteTyping(in:)``). Answers
    /// whether a cue went out.
    @discardableResult
    public func noteTyping(in thread: String) -> Bool {
        defer { settle() }
        return engine.noteTyping(in: thread)
    }

    /// Changes our profile and floods it.
    public func updateProfile(name: String, status: String, openToChat: Bool) {
        engine.updateProfile(name: name, status: status, openToChat: openToChat)
        settle()
    }

    /// Sets our photo, a JPEG, or clears it with `nil`, floods the profile that names it, and pushes it to every
    /// neighbour (``MeshEngine/setAvatar(_:)``).
    public func setAvatar(_ jpeg: [UInt8]?) {
        engine.setAvatar(jpeg)
        settle()
    }

    /// Marks a pinned peer verified, or not (``MeshEngine/setVerified(_:_:)``), and fetches the photos a verification
    /// accepts.
    public func setVerified(_ peer: NodeId, _ verified: Bool) {
        engine.setVerified(peer, verified)
        spool.markTableDirty()
        settle()
    }

    /// Refuses links with `peer`, both ways, until ``permitLinks(with:)`` (``LinkManager/refuse(_:)``).
    public func refuseLinks(with peer: NodeId) {
        apply(links.refuse(peer))
        settle()
    }

    /// Lets `peer` link again.
    public func permitLinks(with peer: NodeId) {
        apply(links.permit(peer))
        settle()
    }

    /// Whether the app is in the background, where iOS may suspend it, so the links seek peers while none is up
    /// (``LinkManager/setInBackground(_:)``). Kept while stopped, for the next start.
    public func setInBackground(_ background: Bool) {
        apply(links.setInBackground(background))
        settle()
    }

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

    // MARK: Plumbing

    /// After any work: hand on the engine's events, re-advertise a changed digest cue, and aim the timer at the
    /// next deadline. Not private, so a send in an extension in another file settles too (`Mesh+Ratchet.swift`).
    func settle() {
        // A feed's reading moved under whatever just ran: the holder re-reads its parked asks on the edge.
        if links.takeFeedsChanged() {
            engine.fileFeedsChanged()
        }
        publish()
        if engine.custodyRevision != advertisedRevision {
            advertisedRevision = engine.custodyRevision
            links.updateDigestCue(engine.digestCue)
            // The one place a custody change is noticed: every relay's scopes look again (ADR 2026-11.adrq, P4a).
            spool.custodyChanged()
        }
        // After the work's outermost commit: a session row that moved reads the scope table again.
        spool.refreshTable(engine: engine)
        // Before the timer is aimed: a listing's limiter release and first slot edge are deadlines too (ADR 2026-11.sv5t).
        engine.feedPresenceKeys()
        schedule()
    }

    private func publish() {
        for event in engine.drainEvents() {
            continuation.yield(event)
        }
    }

    private func schedule() {
        // A stopped mesh keeps its deadlines, and the next start fires whatever fell due meanwhile.
        let next = isRunning ? [engine.nextDeadline, links.nextDeadline, spool.nextDeadline].compactMap(\.self).min() : nil
        guard next != scheduled else {
            return
        }
        timer?.cancel()
        scheduled = next
        timer = next.map { deadline in
            Task { [weak self, clock] in
                do {
                    try await clock.sleep(untilMonotonic: deadline)
                } catch {
                    return
                }
                await self?.timerFired(for: deadline)
            }
        }
    }

    private func timerFired(for deadline: Int64) {
        // A timer superseded while it slept finds another deadline in place, and leaves it be.
        if scheduled == deadline {
            scheduled = nil
            fireDueTimers()
        }
    }
}

extension Mesh {
    /// Hands each link event to the engine, in order.
    func apply(_ linkEvents: [LinkManager.Event]) {
        for event in linkEvents {
            switch event {
            case .up(let neighbor):
                engine.linkUp(neighbor)
            case .down(let nodeId):
                engine.linkDown(nodeId)
            case .frame(let frame):
                engine.receive(frame)
            case .digest(let ids, let from):
                engine.receiveDigest(ids, from: from)
            case .file(let file):
                engine.receiveFile(file)
            case .fileProgress(let progress):
                engine.fileProgress(progress)
            case .fileSent(let hash, let peer):
                engine.fileSent(hash, to: peer)
            case .fileOverLimit(let hash, let peer):
                engine.fileOverLimit(hash, from: peer)
            }
        }
    }
}
