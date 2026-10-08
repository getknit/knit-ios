public import KnitMesh
public import KnitStore
import KnitSync
public import KnitWire

/// A demo scene's mesh: the real ``Mesh`` on the demo's radio, reporting the scene's peers as linked while it runs
/// with the radio on. The demo's radio links nobody, so without this the status line only ever says it is looking,
/// and no screenshot shows who is nearby. Everything else passes through, so what the demo sends still waits in
/// custody. A scene with a script also has a ``DemoDirector``, which plays it here once the mesh first starts.
public final class DemoMesh: MeshService, DemoDirector.Stage {
    /// The peers shown as linked, which the director adds to.
    private let linked: Lock<[Neighbor]>
    private let mesh: any MeshService
    private let director: DemoDirector?
    private let continuation: AsyncStream<MeshEvent>.Continuation
    private let pump: Task<Void, Never>
    /// The director's performance, once the mesh has started.
    private let performance = Lock<Task<Void, Never>?>(nil)
    /// The mesh's events, with every change of the radio's state or the links answered by the links shown now.
    public let events: AsyncStream<MeshEvent>

    /// `mesh`, reporting `linked` as linked, and playing `director`'s script once it starts.
    public init(_ mesh: any MeshService, linked: [NodeId], director: DemoDirector? = nil) {
        let shown = Lock(linked.map { Neighbor(nodeId: $0) })
        let (stream, sink) = AsyncStream<MeshEvent>.makeStream()
        self.linked = shown
        self.mesh = mesh
        self.director = director
        events = stream
        continuation = sink
        pump = Task {
            for await event in mesh.events {
                switch event {
                case .neighborsChanged:
                    sink.yield(.neighborsChanged(await Self.shown(shown, by: mesh)))
                case .radioChanged:
                    sink.yield(event)
                    sink.yield(.neighborsChanged(await Self.shown(shown, by: mesh)))
                default:
                    sink.yield(event)
                }
            }
            sink.finish()
        }
    }

    deinit {
        pump.cancel()
        performance.withLock { $0?.cancel() }
        continuation.finish()
    }

    /// `linked` while `mesh` runs with the radio on, since a stopped mesh or a radio that cannot run links nobody.
    private static func shown(_ linked: Lock<[Neighbor]>, by mesh: any MeshService) async -> [Neighbor] {
        let running = await mesh.isRunning
        let radio = await mesh.radioState
        return running && radio == .on ? linked.withLock { $0 } : []
    }

    // MARK: The director's stage

    /// Shows `peer` as linked from now on, and says so.
    func link(_ peer: NodeId) async {
        linked.withLock { shown in
            if !shown.contains(where: { $0.nodeId == peer }) {
                shown.append(Neighbor(nodeId: peer))
            }
        }
        continuation.yield(.neighborsChanged(await neighbors))
    }

    /// Tells the session that `event` happened.
    func announce(_ event: MeshEvent) {
        continuation.yield(event)
    }

    /// This node's id.
    public var nodeId: NodeId {
        mesh.nodeId
    }

    /// Whether the mesh runs.
    public var isRunning: Bool {
        get async { await mesh.isRunning }
    }

    /// What the radio last said of its state.
    public var radioState: RadioState? {
        get async { await mesh.radioState }
    }

    /// The peers shown as linked.
    public var neighbors: [Neighbor] {
        get async { await Self.shown(linked, by: mesh) }
    }

    /// The mesh's counters, with the peers shown as linked.
    public var diagnostics: MeshDiagnostics {
        get async {
            var counters = await mesh.diagnostics
            counters.neighbors = await neighbors
            return counters
        }
    }

    /// Starts the mesh, and shows the links once the radio is on. The first start also starts the director.
    public func start() async {
        await mesh.start()
        continuation.yield(.neighborsChanged(await neighbors))
        guard let director else {
            return
        }
        performance.withLock { playing in
            if playing == nil {
                playing = Task { [self] in await director.play(on: self) }
            }
        }
    }

    /// Stops the mesh, which closes every link shown.
    public func stop() async {
        await mesh.stop()
        continuation.yield(.neighborsChanged([]))
    }

    /// Posts to the Nearby room, where nobody hears it but the director.
    public func postToRoom(_ text: String, photo: OutgoingPhoto?) async -> MessageRecord? {
        let posted = await mesh.postToRoom(text, photo: photo)
        if let posted {
            director?.heard(posted)
        }
        return posted
    }

    /// Sends a DM, which waits in custody.
    public func sendDirectMessage(_ text: String, to recipient: NodeId, photo: OutgoingPhoto?) async -> MessageRecord? {
        await mesh.sendDirectMessage(text, to: recipient, photo: photo)
    }

    /// Accepts a message request.
    public func accept(_ conversationId: String) async {
        await mesh.accept(conversationId)
    }

    /// Makes a group, whose first message will wait in custody.
    public func createGroup(with others: [NodeId]) async -> GroupRecord? {
        await mesh.createGroup(with: others)
    }

    /// Sends a group message, which waits in custody.
    public func sendGroupMessage(_ text: String, to groupId: String, photo: OutgoingPhoto?) async -> MessageRecord? {
        await mesh.sendGroupMessage(text, to: groupId, photo: photo)
    }

    /// Renames a group.
    public func renameGroup(_ groupId: String, to name: String) async -> GroupRecord? {
        await mesh.renameGroup(groupId, to: name)
    }

    /// Leaves a group.
    public func leaveGroup(_ groupId: String) async -> Bool {
        await mesh.leaveGroup(groupId)
    }

    /// Deletes a message.
    public func deleteMessage(_ id: String) async -> Bool {
        await mesh.deleteMessage(id)
    }

    /// Deletes a thread.
    public func deleteChat(_ conversationId: String) async -> Bool {
        await mesh.deleteChat(conversationId)
    }

    /// Reacts to a message.
    public func react(to messageId: String, with emoji: String) async -> ReactionRecord? {
        await mesh.react(to: messageId, with: emoji)
    }

    /// Changes our profile.
    public func updateProfile(name: String, status: String, openToChat: Bool) async {
        await mesh.updateProfile(name: name, status: status, openToChat: openToChat)
    }

    public func setAvatar(_ jpeg: [UInt8]?) async {
        await mesh.setAvatar(jpeg)
    }

    /// Marks a pinned peer verified, or not.
    public func setVerified(_ peer: NodeId, _ verified: Bool) async {
        await mesh.setVerified(peer, verified)
    }

    /// Blocks a person.
    public func block(_ peer: NodeId) async {
        await mesh.block(peer)
    }

    /// Unblocks a person.
    public func unblock(_ peer: NodeId) async {
        await mesh.unblock(peer)
    }
}
