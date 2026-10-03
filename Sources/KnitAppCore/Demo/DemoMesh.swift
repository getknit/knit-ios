public import KnitMesh
public import KnitStore
public import KnitWire

/// A demo scene's mesh: the real ``Mesh`` on the demo's radio, reporting the scene's peers as linked while it runs
/// with the radio on. The demo's radio links nobody, so without this the status line only ever says it is looking,
/// and no screenshot shows who is nearby. Everything else passes through, so what the demo sends still waits in
/// custody.
public final class DemoMesh: MeshService {
    /// The peers shown as linked.
    private let linked: [Neighbor]
    private let mesh: any MeshService
    private let continuation: AsyncStream<MeshEvent>.Continuation
    private let pump: Task<Void, Never>
    /// The mesh's events, with every change of the radio's state or the links answered by the links shown now.
    public let events: AsyncStream<MeshEvent>

    /// `mesh`, reporting `linked` as linked.
    public init(_ mesh: any MeshService, linked: [NodeId]) {
        let shown = linked.map { Neighbor(nodeId: $0) }
        let (stream, sink) = AsyncStream<MeshEvent>.makeStream()
        self.linked = shown
        self.mesh = mesh
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
        continuation.finish()
    }

    /// `linked` while `mesh` runs with the radio on, since a stopped mesh or a radio that cannot run links nobody.
    private static func shown(_ linked: [Neighbor], by mesh: any MeshService) async -> [Neighbor] {
        let running = await mesh.isRunning
        let radio = await mesh.radioState
        return running && radio == .on ? linked : []
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

    /// Starts the mesh, and shows the links once the radio is on.
    public func start() async {
        await mesh.start()
        continuation.yield(.neighborsChanged(await neighbors))
    }

    /// Stops the mesh, which closes every link shown.
    public func stop() async {
        await mesh.stop()
        continuation.yield(.neighborsChanged([]))
    }

    /// Posts to the Nearby room, where nobody hears it.
    public func postToRoom(_ text: String) async -> MessageRecord? {
        await mesh.postToRoom(text)
    }

    /// Sends a DM, which waits in custody.
    public func sendDirectMessage(_ text: String, to recipient: NodeId) async -> MessageRecord? {
        await mesh.sendDirectMessage(text, to: recipient)
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
    public func sendGroupMessage(_ text: String, to groupId: String) async -> MessageRecord? {
        await mesh.sendGroupMessage(text, to: groupId)
    }

    /// Renames a group.
    public func renameGroup(_ groupId: String, to name: String) async -> GroupRecord? {
        await mesh.renameGroup(groupId, to: name)
    }

    /// Leaves a group.
    public func leaveGroup(_ groupId: String) async -> Bool {
        await mesh.leaveGroup(groupId)
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
}
