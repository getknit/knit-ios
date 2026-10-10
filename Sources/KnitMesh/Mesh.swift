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

    private let engine: MeshEngine
    private let links: LinkManager
    private let radio: any Radio
    private let clock: any MeshClock
    private let continuation: AsyncStream<MeshEvent>.Continuation
    private var eventLoop: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var scheduled: Int64?
    private var advertisedRevision = -1

    /// Whether the mesh is running: started, and not stopped since.
    public private(set) var isRunning = false
    /// What the radio last said of its state, or `nil` before it has said anything.
    public private(set) var radioState: RadioState?

    /// A mesh node for `identity`, on `radio`.
    public init(
        identity: IdentityKeys,
        deviceTag: String?,
        stores: MeshStores,
        radio: any Radio,
        clock: any MeshClock,
        random: some RandomNumberGenerator & Sendable,
        configuration: MeshConfiguration = MeshConfiguration(),
        linkConfiguration: LinkManager.Configuration = LinkManager.Configuration(),
        log: any KnitLog = SilentLog()
    ) {
        let linkManager = LinkManager(
            localId: identity.nodeId,
            radio: radio,
            clock: clock,
            random: random,
            configuration: linkConfiguration,
            log: log
        )
        links = linkManager
        engine = MeshEngine(
            identity: identity,
            deviceTag: deviceTag,
            stores: stores,
            transport: linkManager,
            clock: clock,
            random: random,
            configuration: configuration,
            log: log
        )
        self.radio = radio
        self.clock = clock
        nodeId = identity.nodeId
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
        engine.start()
        links.start()
        if eventLoop == nil {
            eventLoop = Task { [weak self, events = radio.events] in
                for await event in events {
                    await self?.process(event)
                }
            }
        }
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
        apply(links.stop())
        publish()
    }

    /// Handles one radio event: what the radio's stream delivers, one at a time. While stopped, only a change of
    /// state is heard.
    public func process(_ event: RadioEvent) {
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
        settle()
    }

    // MARK: The app's side

    /// Posts to the Nearby room, with a photo if one is given.
    @discardableResult
    public func postToRoom(_ text: String, photo: OutgoingPhoto? = nil) -> MessageRecord? {
        defer { settle() }
        return engine.postToRoom(text, photo: photo)
    }

    /// Sends a DM, with a photo if one is given.
    @discardableResult
    public func sendDirectMessage(_ text: String, to recipient: NodeId, photo: OutgoingPhoto? = nil) -> MessageRecord? {
        defer { settle() }
        return engine.sendDirectMessage(text, to: recipient, photo: photo)
    }

    /// `picked` as the picture this phone already holds it as, or `nil` (``MeshEngine/heldPhoto(picked:)``).
    public func heldPhoto(picked: [UInt8]) -> OutgoingPhoto? {
        engine.heldPhoto(picked: picked)
    }

    /// Accepts a message request.
    public func accept(_ conversationId: String) {
        engine.accept(conversationId)
    }

    /// Makes a group with `others`, or opens the one they already share (``MeshEngine/createGroup(with:)``).
    @discardableResult
    public func createGroup(with others: [NodeId]) -> GroupRecord? {
        defer { publish() }
        return engine.createGroup(with: others)
    }

    /// Sends a message to a group, with a photo if one is given (``MeshEngine/sendGroupMessage(_:to:photo:)``).
    @discardableResult
    public func sendGroupMessage(_ text: String, to groupId: String, photo: OutgoingPhoto? = nil) -> MessageRecord? {
        defer { settle() }
        return engine.sendGroupMessage(text, to: groupId, photo: photo)
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
        defer { settle() }
        return engine.deleteChat(conversationId)
    }

    /// Reacts to a message, or takes our reaction back, and floods it (``MeshEngine/react(to:with:)``, ADR 2026-10.ehe6).
    @discardableResult
    public func react(to messageId: String, with emoji: String) -> ReactionRecord? {
        defer { settle() }
        return engine.react(to: messageId, with: emoji)
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

    /// Marks a pinned peer verified, or not (``MeshEngine/setVerified(_:_:)``).
    public func setVerified(_ peer: NodeId, _ verified: Bool) {
        engine.setVerified(peer, verified)
        publish()
    }

    /// Blocks `peer`: nothing they send is shown, and the mesh carries and relays it as before
    /// (``MeshEngine/block(_:)``, ADR 2026-10.5wgg).
    public func block(_ peer: NodeId) {
        engine.block(peer)
    }

    /// Unblocks `peer` (``MeshEngine/unblock(_:)``).
    public func unblock(_ peer: NodeId) {
        engine.unblock(peer)
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

    /// What the links did with FILE records so far.
    public var files: FileCounts {
        FileCounts(received: links.filesReceived, refused: links.filesRefused + engine.filesRejected, sent: links.filesSent)
    }

    /// What the blob holder query has done so far, both ends.
    public var blobs: BlobCounts { engine.blobCounts }
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
    /// next deadline.
    private func settle() {
        // A feed's reading moved under whatever just ran: the holder re-reads its parked asks on the edge.
        if links.takeFeedsChanged() {
            engine.fileFeedsChanged()
        }
        publish()
        if engine.custodyRevision != advertisedRevision {
            advertisedRevision = engine.custodyRevision
            links.updateDigestCue(engine.digestCue)
        }
        schedule()
    }

    private func publish() {
        for event in engine.drainEvents() {
            continuation.yield(event)
        }
    }

    private func schedule() {
        // A stopped mesh keeps its deadlines, and the next start fires whatever fell due meanwhile.
        let next = isRunning ? [engine.nextDeadline, links.nextDeadline].compactMap(\.self).min() : nil
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
    private func apply(_ linkEvents: [LinkManager.Event]) {
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
            }
        }
    }
}
