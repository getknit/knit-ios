public import KnitMesh
public import KnitStore
public import KnitWire

/// What the app asks of the mesh: ``Mesh`` in the app and in `-seedDemo`, a stand-in in tests. Everything above
/// the radio talks to the mesh through this, and reads what it stored through the stores.
public protocol MeshService: AnyObject, Sendable {
    /// This node's id.
    var nodeId: NodeId { get }
    /// What the mesh did. One consumer, the ``AppSession``.
    var events: AsyncStream<MeshEvent> { get }
    /// Whether the mesh runs.
    var isRunning: Bool { get async }
    /// What the radio last said of its state.
    var radioState: RadioState? { get async }
    /// The peers linked now.
    var neighbors: [Neighbor] { get async }
    /// What Diagnostics shows.
    var diagnostics: MeshDiagnostics { get async }

    /// Starts the mesh and its radio.
    func start() async
    /// Stops the radio and closes every link.
    func stop() async
    /// Posts to the Nearby room, with a photo if one is given, quoting the message it replies to if it replies.
    func postToRoom(_ text: String, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]) async -> MessageRecord?
    /// Sends a DM, with a photo if one is given, quoting the message it replies to if it replies.
    func sendDirectMessage(
        _ text: String, to recipient: NodeId, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]
    ) async -> MessageRecord?
    /// `picked` as the picture this phone already holds it as, ready to send under that blob's identity, or `nil` when
    /// it holds no such picture (ADR 2026-10.f3mv).
    func heldPhoto(picked: [UInt8]) async -> OutgoingPhoto?
    /// Accepts a message request.
    func accept(_ conversationId: String) async
    /// Makes a group with `others`, or opens the one they already share.
    func createGroup(with others: [NodeId]) async -> GroupRecord?
    /// Sends a message to a group, with a photo if one is given, quoting the message it replies to if it replies.
    func sendGroupMessage(
        _ text: String, to groupId: String, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]
    ) async -> MessageRecord?
    /// Renames a group and floods the change.
    func renameGroup(_ groupId: String, to name: String) async -> GroupRecord?
    /// Leaves a group, telling its members.
    func leaveGroup(_ groupId: String) async -> Bool
    /// Deletes one message from this iPhone, sending nothing (ADR 2026-10.u7cq).
    func deleteMessage(_ id: String) async -> Bool
    /// Deletes a whole thread from this iPhone, sending nothing: a group's membership stays (ADR 2026-10.u7cq).
    func deleteChat(_ conversationId: String) async -> Bool
    /// Reacts to a message with `emoji`, or takes our reaction back when it is the one we hold, and floods it in the clear
    /// (ADR 2026-10.ehe6). Answers what we hold now, or `nil` when nothing changed.
    @discardableResult
    func react(to messageId: String, with emoji: String) async -> ReactionRecord?
    /// Tells a thread that we are typing, in the clear and one hop, at most once every 8 s a thread. Answers whether a cue
    /// went out.
    @discardableResult
    func noteTyping(in thread: String) async -> Bool
    /// Changes our profile and floods it.
    func updateProfile(name: String, status: String, openToChat: Bool) async
    /// Sets our photo, a JPEG, or clears it with `nil`, floods the profile that names it, and pushes it to every
    /// neighbour.
    func setAvatar(_ jpeg: [UInt8]?) async
    /// Marks a pinned peer verified, or not.
    func setVerified(_ peer: NodeId, _ verified: Bool) async
    /// Blocks a person: nothing they send is shown, and the mesh carries and relays it as before (ADR 2026-10.5wgg).
    func block(_ peer: NodeId) async
    /// Unblocks a person.
    func unblock(_ peer: NodeId) async
}

/// The mesh's counters and radio view, read in one hop for Diagnostics.
public struct MeshDiagnostics: Sendable, Equatable {
    /// The peers linked now.
    public var neighbors: [Neighbor]
    /// The peers sighted now, linked or not.
    public var sightings: [PresenceTracker.Snapshot]
    /// Why frames were dropped so far.
    public var dropped: [DropReason: Int]
    /// What the links did with FILE records so far.
    public var files: FileCounts

    /// Bundles the counters.
    public init(
        neighbors: [Neighbor] = [],
        sightings: [PresenceTracker.Snapshot] = [],
        dropped: [DropReason: Int] = [:],
        files: FileCounts = FileCounts()
    ) {
        self.neighbors = neighbors
        self.sightings = sightings
        self.dropped = dropped
        self.files = files
    }
}

extension Mesh: MeshService {
    /// The counters and the radio view, read together.
    public var diagnostics: MeshDiagnostics {
        MeshDiagnostics(neighbors: neighbors, sightings: sightings, dropped: dropped, files: files)
    }
}
