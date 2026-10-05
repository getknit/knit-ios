import KnitCrypto
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
    /// Whether the app is in front, which the app keeps current from its scene phase through ``setActive(_:)``.
    public private(set) var isActive = true
    /// Hears every mesh event once the session has handled it: a debug build's bridge reports them to every connection.
    /// The mesh has one stream of events, and the session is its consumer.
    @ObservationIgnored public var eventTap: (@Sendable (MeshEvent) -> Void)?
    /// Whether someone else's abusive words and explicit photos hide: the Content filtering toggle, on until it is turned
    /// off (ADR 2026-10.rpmq, ADR 2026-10.e4kz). It governs only what we are shown; what we send is checked either way,
    /// and every message is screened as it arrives, so turning it back on hides what came while it was off.
    public var filtersContent: Bool {
        didSet {
            preferences.filtersContent = filtersContent
            revision += 1
        }
    }
    /// What a message's words are checked with, sent or received; `nil` checks nothing.
    @ObservationIgnored public let textScreening: TextScreening?

    @ObservationIgnored private let mesh: any MeshService
    @ObservationIgnored private let notifier: (any Notifier)?
    @ObservationIgnored private let preferences: any AppPreferences
    @ObservationIgnored private var visible: String?
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var cachedDirectory = Cached<Int, Directory>()

    /// A session over `mesh` and the stores it writes, posting notifications through `notifier`, screening words with
    /// `textScreening`, and keeping the content filter's toggle in `preferences`.
    public init(
        identity: OwnIdentity,
        stores: MeshStores,
        mesh: any MeshService,
        notifier: (any Notifier)? = nil,
        textScreening: TextScreening? = nil,
        preferences: any AppPreferences = MemoryPreferences()
    ) {
        self.identity = identity
        self.stores = stores
        self.mesh = mesh
        self.notifier = notifier
        self.textScreening = textScreening
        self.preferences = preferences
        filtersContent = preferences.filtersContent
    }

    /// Everyone this device knows, labelled, as of the current revision.
    public var directory: Directory {
        let now = revision
        return cachedDirectory.value(for: now) {
            let own = stores.ownProfile.load()
            return Directory(
                peers: stores.peers.allPeers(),
                blocked: stores.blocks.blockedNodeIds(),
                me: identity.nodeId,
                myName: own.name,
                myPhoto: own.avatarHash
            )
        }
    }

    /// The bytes of a photo the blob store holds, or `nil`. It reads the disk, so the app calls it off the main actor,
    /// as it decodes the photo.
    nonisolated public func photo(_ hash: BlobHash) -> [UInt8]? {
        stores.blobs.bytes(of: hash)
    }

    /// The bytes of a message's photo, off the main actor like ``photo(_:)``: the blob as it is for the room's, or
    /// opened in memory with `key` for a DM's or a group's, whose blob is sealed (`AttachmentCrypto`). `nil` while the
    /// blob is missing, or when the key does not open it.
    nonisolated public func attachment(_ hash: BlobHash, key: String?) -> [UInt8]? {
        let blob = stores.blobs.bytes(of: hash)
        guard let key else {
            return blob
        }
        return blob.flatMap { sealed in Base64.decode(key).flatMap { AttachmentCrypto.open(sealed, key: $0) } }
    }

    /// The threads, and which are requests, as of the current revision.
    public func threads() -> ThreadTable {
        let known = directory
        return ThreadTable(stores: stores, me: identity.nodeId, verified: known.verified, blocked: known.blocked)
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
        await screenWaiting()
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
    /// their order. Someone else's words are screened first, so neither the thread nor the notification shows them
    /// before the content filter has.
    func handle(_ event: MeshEvent) async {
        switch event {
        case .received(var message, let isRequest):
            if message.moderation == .waiting {
                message.moderation = await screen(message)
            }
            revision += 1
            await notify(message, isRequest: isRequest)
        case .delivered, .sent, .reacted, .peerUpdated, .groupChanged, .attachmentArrived:
            revision += 1
        case .neighborsChanged(let linked):
            neighbors = linked
        case .radioChanged(let state):
            radioState = state
        }
    }

    // MARK: Actions

    /// Sends `text` in a thread, with `photo` if one is given: the room, a group, or a DM to the node id the thread is
    /// named for. A photo may go with no words. Answers what was stored, or `nil` when there is nothing to send.
    @discardableResult
    public func send(_ text: String, photo: OutgoingPhoto? = nil, in conversationId: String) async -> MessageRecord? {
        guard let body = Composer.body(of: text) ?? (photo == nil ? nil : "") else {
            return nil
        }
        let sent: MessageRecord?
        if conversationId == Conversations.nearby {
            sent = await mesh.postToRoom(body, photo: photo)
        } else if Conversations.isGroup(conversationId) {
            sent = await mesh.sendGroupMessage(body, to: conversationId, photo: photo)
        } else if let recipient = NodeId(conversationId), recipient != identity.nodeId {
            sent = await mesh.sendDirectMessage(body, to: recipient, photo: photo)
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

    /// Deletes one message from this iPhone (ADR 2026-10.u7cq). Nobody is told, and one of ours already sent still
    /// arrives. Answers whether it was there to delete.
    @discardableResult
    public func deleteMessage(_ id: String) async -> Bool {
        let deleted = await mesh.deleteMessage(id)
        revision += 1
        return deleted
    }

    /// Deletes a whole thread from this iPhone (ADR 2026-10.u7cq): a DM or a group leaves the list until its next
    /// message, and the Nearby room empties and stays. Its notification goes, and the requests notification once none
    /// is left. Nobody is told, and a group keeps us as a member. Answers whether there was anything to delete.
    @discardableResult
    public func deleteChat(_ conversationId: String) async -> Bool {
        let deleted = await mesh.deleteChat(conversationId)
        revision += 1
        await notifier?.withdraw(threadId: conversationId)
        if threads().requests.isEmpty {
            await notifier?.withdraw(threadId: NotificationPolicy.requestsThread)
        }
        return deleted
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

    /// Blocks a person (ADR 2026-10.5wgg): their DM, their requests and what they wrote leave every screen, and the
    /// notifications of their DM, and of requests once none is left, go. They are not told. Never ourselves.
    public func block(_ peer: NodeId) async {
        guard peer != identity.nodeId else {
            return
        }
        await mesh.block(peer)
        revision += 1
        await notifier?.withdraw(threadId: peer.string)
        if threads().requests.isEmpty {
            await notifier?.withdraw(threadId: NotificationPolicy.requestsThread)
        }
    }

    /// Unblocks a person: what they wrote before the block shows again. A DM or room post sent during it never does; a
    /// group message our custody still holds can, at the next start (ADR 2026-10.5wgg).
    public func unblock(_ peer: NodeId) async {
        await mesh.unblock(peer)
        revision += 1
    }

    /// Changes our profile and floods it.
    public func updateProfile(name: String, status: String, openToChat: Bool) async {
        await mesh.updateProfile(name: name, status: status, openToChat: openToChat)
        revision += 1
    }

    /// Sets our photo, a JPEG, or clears it with `nil`, and floods the profile that names it.
    public func setAvatar(_ jpeg: [UInt8]?) async {
        await mesh.setAvatar(jpeg)
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

    /// The app came to the front or left it. Coming back to a thread still on screen takes back what it posted
    /// meanwhile, as Android's `ON_RESUME` does (`ChatViewModel.onChatForeground`): the user is reading it, and a
    /// notification left behind would make the thread's next one a quiet replacement.
    public func setActive(_ active: Bool) async {
        isActive = active
        if active, let visible {
            await notifier?.withdraw(threadId: visible)
        }
    }

    // MARK: Screening

    /// Screens what the engine stored and the app never got to: a launch that follows one stopped mid-screen, or events
    /// heard by nobody. In the order they were stored, before the first event is heard.
    func screenWaiting() async {
        let waiting = stores.messages.waitingForModeration()
        for message in waiting {
            _ = await screen(message)
        }
        if !waiting.isEmpty {
            revision += 1
        }
    }

    /// What the content filter makes of `message`'s words, stored on its row (`InboundPipeline.inboundModeration`).
    /// Words the filter could not read are let through, as Android lets them through: `clear`, for good.
    private func screen(_ message: MessageRecord) async -> MessageModeration {
        if let stored = stores.messages.message(message.id)?.moderation, stored != .waiting {
            return stored
        }
        let inRoom = message.conversationId == Conversations.nearby
        let flagged = await textScreening?.isAbusive(message.body, inRoom: inRoom) ?? false
        let verdict: MessageModeration = flagged ? .flagged : .clear
        stores.messages.setModeration(message.id, to: verdict)
        return verdict
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
            groupTitle: threads.group(message.conversationId).map { GroupNaming.title(of: $0, me: identity.nodeId, directory: directory) },
            filtersContent: filtersContent
        )
        let notification = NotificationPolicy.notification(for: message, isRequest: isRequest, in: context)
        if let notification {
            await notifier.post(notification)
        }
    }
}
