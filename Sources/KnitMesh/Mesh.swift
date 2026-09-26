public import KnitCrypto
public import KnitStore
public import KnitWire

/// The mesh on a real radio (`MeshManager.start` and `MeshService` in knit-next): one actor that owns the
/// ``MeshEngine`` and the ``LinkManager``, feeds them what the ``Radio`` reports, fires their timers when they
/// fall due, and takes the app's sends.
///
/// Both state machines are synchronous, so every radio event, timer and send runs to completion inside the actor,
/// one at a time, and a test can drive the same code without it.
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
        guard eventLoop == nil else {
            return
        }
        engine.start()
        links.start()
        eventLoop = Task { [weak self, events = radio.events] in
            for await event in events {
                await self?.process(event)
            }
        }
        settle()
    }

    /// Stops the radio and closes every link.
    public func stop() {
        eventLoop?.cancel()
        eventLoop = nil
        timer?.cancel()
        timer = nil
        scheduled = nil
        apply(links.stop())
        publish()
    }

    /// Handles one radio event: what the radio's stream delivers, one at a time.
    public func process(_ event: RadioEvent) {
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

    /// Posts to the Nearby room.
    @discardableResult
    public func postToRoom(_ text: String) -> MessageRecord? {
        defer { settle() }
        return engine.postToRoom(text)
    }

    /// Sends a DM.
    @discardableResult
    public func sendDirectMessage(_ text: String, to recipient: NodeId) -> MessageRecord? {
        defer { settle() }
        return engine.sendDirectMessage(text, to: recipient)
    }

    /// Accepts a message request.
    public func accept(_ conversationId: String) {
        engine.accept(conversationId)
    }

    /// Changes our profile and floods it.
    public func updateProfile(name: String, status: String, openToChat: Bool) {
        engine.updateProfile(name: name, status: status, openToChat: openToChat)
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

    /// The peers linked now.
    public var neighbors: [Neighbor] { links.neighbors }

    /// The peers sighted now, linked or not.
    public var sightings: [PresenceTracker.Snapshot] { links.sightings() }

    /// Why frames were dropped so far.
    public var dropped: [DropReason: Int] { engine.dropped }

    // MARK: Plumbing

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
            }
        }
    }

    /// After any work: hand on the engine's events, re-advertise a changed digest cue, and aim the timer at the
    /// next deadline.
    private func settle() {
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
        let next = [engine.nextDeadline, links.nextDeadline].compactMap(\.self).min()
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
