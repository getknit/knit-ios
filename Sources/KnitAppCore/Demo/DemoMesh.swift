public import KnitCrypto
public import KnitMesh
public import KnitStore
import KnitSync
public import KnitWire

/// A demo scene's mesh: the real ``Mesh`` on the demo's radio, reporting the scene's peers as linked while it runs
/// with the radio on. The demo's radio links nobody, so without this the status line only ever says it is looking,
/// and no screenshot shows who is nearby. It shows the scene's typists the same way, held for as long as the links are,
/// as Android's demo holds its own (`MeshManager.seedPersistent`). Everything else passes through, so what the demo sends
/// still waits in custody. A scene with a script also has a ``DemoDirector``, which plays it here once the mesh first
/// starts.
public final class DemoMesh: MeshService, DemoDirector.Stage {
    /// The peers shown as linked, which the director adds to.
    private let linked: Lock<[Neighbor]>
    /// Who is shown typing where.
    private let typists: [String: [NodeId]]
    /// The photos shown on their way, each as far as it has got.
    private let arriving: [BlobHash: FileIntake.Reading]
    private let mesh: any MeshService
    private let director: DemoDirector?
    private let continuation: AsyncStream<MeshEvent>.Continuation
    private let pump: Task<Void, Never>
    /// The director's performance.
    private let performance = Lock(Performance.waiting)
    /// The mesh's events, with every change of the radio's state or the links answered by the links shown now.
    public let events: AsyncStream<MeshEvent>

    /// `mesh`, reporting `linked` as linked, `typing` as typing and `arriving` as streaming in, and playing `director`'s
    /// script once it starts.
    public init(
        _ mesh: any MeshService,
        linked: [NodeId],
        typing: [String: [NodeId]] = [:],
        arriving: [BlobHash: FileIntake.Reading] = [:],
        director: DemoDirector? = nil
    ) {
        let shown = Lock(linked.map { Neighbor(nodeId: $0) })
        let (stream, sink) = AsyncStream<MeshEvent>.makeStream()
        self.linked = shown
        typists = typing
        self.arriving = arriving
        self.mesh = mesh
        self.director = director
        events = stream
        continuation = sink
        pump = Task {
            for await event in mesh.events {
                switch event {
                case .neighborsChanged:
                    await Self.announce(shown, by: mesh, to: sink)
                case .radioChanged:
                    sink.yield(event)
                    await Self.announce(shown, by: mesh, to: sink)
                    if !typing.isEmpty {
                        sink.yield(.typing(await Self.typing(typing, over: [:], by: mesh)))
                    }
                case .typing(let picture):
                    sink.yield(.typing(await Self.typing(typing, over: picture, by: mesh)))
                default:
                    sink.yield(event)
                }
            }
            sink.finish()
        }
    }

    deinit {
        end()
    }

    /// `linked` while `mesh` runs with the radio on, since a stopped mesh or a radio that cannot run links nobody.
    private static func shown(_ linked: Lock<[Neighbor]>, by mesh: any MeshService) async -> [Neighbor] {
        let running = await mesh.isRunning
        let radio = await mesh.radioState
        return running && radio == .on ? linked.withLock { $0 } : []
    }

    /// Says on `sink` who is shown linked now. The links are read and said under their lock, so the pump and the
    /// director's ``link(_:)`` say them in the order they read them: a pump that read them before the director added
    /// someone can never land after the director's word and take that someone off the status line.
    private static func announce(
        _ linked: Lock<[Neighbor]>, by mesh: any MeshService, to sink: AsyncStream<MeshEvent>.Continuation
    ) async {
        let running = await mesh.isRunning
        let radio = await mesh.radioState
        linked.withLock { shown in
            _ = sink.yield(.neighborsChanged(running && radio == .on ? shown : []))
        }
    }

    /// `picture` with `shown` laid over it while `mesh` runs with the radio on, as the links are.
    private static func typing(
        _ shown: [String: [NodeId]], over picture: [String: [NodeId]], by mesh: any MeshService
    ) async -> [String: [NodeId]] {
        let running = await mesh.isRunning
        let radio = await mesh.radioState
        guard running, radio == .on else {
            return picture
        }
        return picture.merging(shown) { Array(Set($0 + $1)).sorted() }
    }

    // MARK: The director's stage

    /// Shows `peer` as linked from now on, and says so.
    func link(_ peer: NodeId) async {
        linked.withLock { shown in
            if !shown.contains(where: { $0.nodeId == peer }) {
                shown.append(Neighbor(nodeId: peer))
            }
        }
        await Self.announce(linked, by: mesh, to: continuation)
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

    /// `mesh`, showing what `staging` stages, and playing `director`'s script once it starts.
    public convenience init(_ mesh: any MeshService, staging: Staging, director: DemoDirector? = nil) {
        self.init(mesh, linked: staging.linked, typing: staging.typing, arriving: staging.arriving, director: director)
    }

    /// The files streaming in, with the photos shown on their way laid over them.
    public var arrivingFiles: [BlobHash: FileIntake.Reading] {
        get async { await mesh.arrivingFiles.merging(arriving) { _, shown in shown } }
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
        await Self.announce(linked, by: mesh, to: continuation)
        if !typists.isEmpty {
            continuation.yield(.typing(await Self.typing(typists, over: [:], by: mesh)))
        }
        guard let director else {
            return
        }
        performance.withLock { state in
            if case .waiting = state {
                state = .playing(Task { [self] in await director.play(on: self) })
            }
        }
    }

    /// Stops the mesh, which closes every link shown.
    public func stop() async {
        await mesh.stop()
        continuation.yield(.neighborsChanged([]))
        if !typists.isEmpty {
            continuation.yield(.typing([:]))
        }
    }

    /// Ends the director's performance and these events, for the sample chats, which close while Knit runs on (ADR
    /// 2026-11.pydf). The performance holds this mesh, so without this it would outlive them. A start still on its way
    /// finds it ended and plays nothing.
    public func end() {
        performance.withLock { state in
            if case .playing(let task) = state {
                task.cancel()
            }
            state = .ended
        }
        pump.cancel()
        continuation.finish()
    }

    /// Posts to the Nearby room, where nobody hears it but the director.
    public func postToRoom(
        _ text: String, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]
    ) async -> MessageRecord? {
        let posted = await mesh.postToRoom(text, photo: photo, replyTo: replyTo, mentions: mentions)
        if let posted {
            director?.heard(posted)
        }
        return posted
    }

    /// Sends a DM, which waits in custody and which the director hears.
    public func sendDirectMessage(
        _ text: String, to recipient: NodeId, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]
    ) async -> MessageRecord? {
        let sent = await mesh.sendDirectMessage(text, to: recipient, photo: photo, replyTo: replyTo, mentions: mentions)
        if let sent {
            director?.heard(sent)
        }
        return sent
    }

    /// A picture the demo already holds, as the mesh finds it.
    public func heldPhoto(picked: [UInt8]) async -> OutgoingPhoto? {
        await mesh.heldPhoto(picked: picked)
    }

    /// Accepts a message request.
    public func accept(_ conversationId: String) async {
        await mesh.accept(conversationId)
    }

    /// Makes a group, whose first message will wait in custody.
    public func createGroup(with others: [NodeId]) async -> GroupRecord? {
        await mesh.createGroup(with: others)
    }

    /// Sends a group message, which waits in custody and which the director hears.
    public func sendGroupMessage(
        _ text: String, to groupId: String, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]
    ) async -> MessageRecord? {
        let sent = await mesh.sendGroupMessage(text, to: groupId, photo: photo, replyTo: replyTo, mentions: mentions)
        if let sent {
            director?.heard(sent)
        }
        return sent
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

    /// Tells a thread we are typing, which nobody hears.
    public func noteTyping(in thread: String) async -> Bool {
        await mesh.noteTyping(in: thread)
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

    /// Adds the person a link or a scanned code names.
    public func addContact(_ card: ContactCard.Card, from source: ContactSource, unblock: Bool) async -> ContactAdded {
        await mesh.addContact(card, from: source, unblock: unblock)
    }

    /// Our contact link, signed by this scene's identity: the demo's fixed one, or the sample chats' own.
    public func ownContactLink() async -> ContactCard.Links? {
        await mesh.ownContactLink()
    }

    /// Blocks a person, and tells the director, whose script may be waiting for it.
    public func block(_ peer: NodeId) async {
        await mesh.block(peer)
        director?.blocked(peer)
    }

    /// Unblocks a person.
    public func unblock(_ peer: NodeId) async {
        await mesh.unblock(peer)
    }
}

extension DemoMesh {
    /// Where the director's performance stands: the first start begins it, and ``end()`` stops it for good.
    private enum Performance {
        case waiting
        case playing(Task<Void, Never>)
        case ended
    }

    /// What a scene shows that the demo's radio cannot make true: who is linked, who is typing where, and which photos are
    /// on their way.
    public struct Staging: Sendable {
        /// The peers shown as linked.
        public var linked: [NodeId] = []
        /// Who is shown typing where.
        public var typing: [String: [NodeId]] = [:]
        /// The photos shown on their way, each as far as it has got.
        public var arriving: [BlobHash: FileIntake.Reading] = [:]

        /// Nothing staged.
        public init() {
            // Nothing is staged yet.
        }

        /// Whether it stages nothing, so the real mesh can stand alone.
        public var isEmpty: Bool {
            linked.isEmpty && typing.isEmpty && arriving.isEmpty
        }
    }
}
