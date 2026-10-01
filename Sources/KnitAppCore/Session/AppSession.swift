public import KnitMesh
public import KnitStore
public import KnitWire
public import Observation

/// The app's one view of the mesh: what it is doing now, and the actions every screen takes (`MeshManager` as the
/// Android view models see it). The view models read state here and messages from the stores; the stores stay the
/// source of truth.
///
/// ``revision`` moves whenever the stores may hold something new, from a mesh event or an action taken here, so a
/// view model rebuilds only then. Everything runs on the main actor, and the mesh is an actor of its own.
@preconcurrency
@MainActor
@Observable
public final class AppSession {
    /// This device's identity.
    public let identity: OwnIdentity
    /// The repositories the mesh writes.
    public let stores: MeshStores
    /// What the radio last said, or `nil` before it has said anything.
    public private(set) var radioState: RadioState?
    /// The peers linked now.
    public private(set) var neighbors: [Neighbor] = []
    /// Whether the mesh runs: false before the first start, and after Settings' Stop.
    public private(set) var isRunning = false
    /// Moves whenever messages, peers, conversations or our own profile may have changed.
    public private(set) var revision = 0
    /// Whether the app is in front, which the app keeps current from its scene phase.
    public var isActive = true
    /// Hears every mesh event once the session has handled it: a debug build's bridge reports them over USB. The mesh
    /// has one stream of events, and the session is its consumer.
    @ObservationIgnored public var eventTap: (@Sendable (MeshEvent) -> Void)?

    @ObservationIgnored private let mesh: any MeshService
    @ObservationIgnored private let notifier: (any Notifier)?
    @ObservationIgnored private var visible: String?
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var cachedDirectory = Cached<Int, Directory>()

    /// A session over `mesh` and the stores it writes, posting notifications through `notifier`.
    public init(identity: OwnIdentity, stores: MeshStores, mesh: any MeshService, notifier: (any Notifier)? = nil) {
        self.identity = identity
        self.stores = stores
        self.mesh = mesh
        self.notifier = notifier
    }

    /// Everyone this device knows, labelled, as of the current revision.
    public var directory: Directory {
        let now = revision
        return cachedDirectory.value(for: now) {
            Directory(peers: stores.peers.allPeers(), me: identity.nodeId, myName: stores.ownProfile.load().name)
        }
    }

    /// The threads, and which are requests, as of the current revision.
    public func threads() -> ThreadTable {
        ThreadTable(stores: stores, me: identity.nodeId, verified: directory.verified)
    }

    // MARK: Running

    /// Hands on what the mesh does until the calling task is cancelled. Call it once, from the app's root task.
    public func listen() async {
        guard !listening else {
            return
        }
        listening = true
        radioState = await mesh.radioState
        isRunning = await mesh.isRunning
        for await event in mesh.events {
            await handle(event)
            eventTap?(event)
        }
    }

    /// Starts the mesh and its radio. On a first run this is what asks for Bluetooth.
    public func start() async {
        await mesh.start()
        isRunning = await mesh.isRunning
    }

    /// Stops the mesh: every link closes, and what the user writes waits in custody.
    public func stop() async {
        await mesh.stop()
        isRunning = await mesh.isRunning
    }

    /// One thing the mesh did. A notification it calls for is posted before the next event is heard, so they keep
    /// their order.
    func handle(_ event: MeshEvent) async {
        switch event {
        case .received(let message, let isRequest):
            revision += 1
            await notify(message, isRequest: isRequest)
        case .delivered, .sent, .peerUpdated, .groupChanged:
            revision += 1
        case .neighborsChanged(let linked):
            neighbors = linked
        case .radioChanged(let state):
            radioState = state
        }
    }

    // MARK: Actions

    /// Sends `text` in a thread: the room, a group, or a DM to the node id the thread is named for. Answers what was
    /// stored, or `nil` when there is nothing to send.
    @discardableResult
    public func send(_ text: String, in conversationId: String) async -> MessageRecord? {
        guard let body = Composer.body(of: text) else {
            return nil
        }
        let sent: MessageRecord?
        if conversationId == Conversations.nearby {
            sent = await mesh.postToRoom(body)
        } else if Conversations.isGroup(conversationId) {
            sent = await mesh.sendGroupMessage(body, to: conversationId)
        } else if let recipient = NodeId(conversationId), recipient != identity.nodeId {
            sent = await mesh.sendDirectMessage(body, to: recipient)
        } else {
            return nil
        }
        revision += 1
        return sent
    }

    /// Makes a group with `others`, or opens the one they already share. Answers it, or `nil` for a pick the mesh
    /// refuses.
    @discardableResult
    public func createGroup(with others: [NodeId]) async -> GroupRecord? {
        let group = await mesh.createGroup(with: others)
        revision += 1
        return group
    }

    /// Renames a group, and tells its members. Answers it, or `nil` for a blank name or a group we are not in.
    @discardableResult
    public func renameGroup(_ groupId: String, to name: String) async -> GroupRecord? {
        let group = await mesh.renameGroup(groupId, to: name)
        revision += 1
        return group
    }

    /// Leaves a group: its members hear of it, and its thread and notifications go. Answers whether we were in it.
    @discardableResult
    public func leaveGroup(_ groupId: String) async -> Bool {
        let left = await mesh.leaveGroup(groupId)
        revision += 1
        await notifier?.withdraw(threadId: groupId)
        return left
    }

    /// Accepts a message request, and takes back the requests notification once none waits.
    public func accept(_ conversationId: String) async {
        await mesh.accept(conversationId)
        revision += 1
        if threads().requests.isEmpty {
            await notifier?.withdraw(threadId: NotificationPolicy.requestsThread)
        }
    }

    /// Marks a peer verified, or not.
    public func setVerified(_ peer: NodeId, _ verified: Bool) async {
        await mesh.setVerified(peer, verified)
        revision += 1
    }

    /// Changes our profile and floods it.
    public func updateProfile(name: String, status: String, openToChat: Bool) async {
        await mesh.updateProfile(name: name, status: status, openToChat: openToChat)
        revision += 1
    }

    /// What Diagnostics shows now.
    public func diagnostics() async -> MeshDiagnostics {
        await mesh.diagnostics
    }

    // MARK: The thread on screen

    /// A thread came on screen: it stays quiet while it is there, and what it posted before goes.
    public func show(_ conversationId: String) async {
        visible = conversationId
        await notifier?.withdraw(threadId: conversationId)
    }

    /// A thread left the screen.
    public func hide(_ conversationId: String) {
        if visible == conversationId {
            visible = nil
        }
    }

    private func notify(_ message: MessageRecord, isRequest: Bool) async {
        guard let notifier else {
            return
        }
        let threads = threads()
        let context = NotificationPolicy.Context(
            me: identity.nodeId,
            visibleConversation: isActive ? visible : nil,
            directory: directory,
            pendingRequests: isRequest ? threads.requests.count : 0,
            groupTitle: threads.group(message.conversationId).map { GroupNaming.title(of: $0, me: identity.nodeId, directory: directory) }
        )
        let notification = NotificationPolicy.notification(for: message, isRequest: isRequest, in: context)
        if let notification {
            await notifier.post(notification)
        }
    }
}
