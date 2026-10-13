import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire

@testable import KnitAppCore

/// A person with fixed keys.
struct Person {
    let keys: IdentityKeys

    init(seed: Int) {
        guard let made = IdentityKeys(signingSeed: fixtureBytes(32, seed: seed), agreementScalar: fixtureBytes(32, seed: seed + 100)) else {
            fatalError("fixed seeds make valid keys")
        }
        keys = made
    }

    var nodeId: NodeId { keys.nodeId }
    var bundle: PublicKeyBundle { keys.bundle }

    /// The peer row our engine would pin for this person.
    func record(name: String, status: String = "", verified: Bool = false, openToChat: Bool = false) -> PeerRecord {
        PeerRecord(
            nodeId: nodeId,
            name: name,
            status: status,
            publicKey: bundle.encoded,
            updatedAt: 1,
            verified: verified,
            openToChat: openToChat
        )
    }
}

/// A mesh that does what the engine does to the stores for each of the app's calls, records them, and reports
/// whatever the test emits.
final class FakeMesh: MeshService {
    struct Calls: Equatable {
        var starts = 0
        var stops = 0
        var room: [String] = []
        var direct: [String] = []
        var accepted: [String] = []
        var verified: [String] = []
        var blocked: [String] = []
        var profiles: [String] = []
        var avatars: [BlobHash?] = []
        var photos: [BlobHash] = []
        var groups: [String] = []
        var deleted: [String] = []
        var reactions: [String] = []
    }

    let nodeId: NodeId
    let events: AsyncStream<MeshEvent>
    private let continuation: AsyncStream<MeshEvent>.Continuation
    private let stores: MeshStores
    private struct State {
        var calls = Calls()
        var running = false
        var radio: RadioState?
        var next = 0
    }

    private let state: Lock<State>
    /// The pictures this mesh holds, by the hash of the bytes a pick hands over (`FakeMesh+Photos.swift`).
    let held = Lock<[BlobHash: OutgoingPhoto]>([:])
    let clock: Int64

    init(nodeId: NodeId, stores: MeshStores, radio: RadioState? = nil, clock: Int64 = 1_790_000_000_000) {
        self.nodeId = nodeId
        self.stores = stores
        self.clock = clock
        state = Lock(State(radio: radio))
        (events, continuation) = AsyncStream<MeshEvent>.makeStream()
    }

    var calls: Calls { state.withLock { $0.calls } }

    /// Reports `event`, as the mesh would.
    func emit(_ event: MeshEvent) {
        continuation.yield(event)
    }

    /// Ends the event stream, so a listening session returns.
    func finish() {
        continuation.finish()
    }

    var isRunning: Bool { state.withLock { $0.running } }
    var radioState: RadioState? { state.withLock { $0.radio } }
    var neighbors: [Neighbor] { [] }
    var diagnostics: MeshDiagnostics { MeshDiagnostics() }

    func start() {
        state.withLock { state in
            state.calls.starts += 1
            state.running = true
        }
    }

    func stop() {
        state.withLock { state in
            state.calls.stops += 1
            state.running = false
        }
    }

    func postToRoom(_ text: String, photo: OutgoingPhoto?, replyTo: MessageReply?) -> MessageRecord? {
        state.withLock { $0.calls.room.append(text) }
        return store(text, to: nil, photo: photo, replyTo: replyTo)
    }

    func sendDirectMessage(_ text: String, to recipient: NodeId, photo: OutgoingPhoto?, replyTo: MessageReply?) -> MessageRecord? {
        state.withLock { $0.calls.direct.append("\(recipient): \(text)") }
        return store(text, to: recipient, photo: photo, replyTo: replyTo)
    }

    func accept(_ conversationId: String) {
        state.withLock { $0.calls.accepted.append(conversationId) }
        stores.conversations.accept(conversationId)
    }

    func updateProfile(name: String, status: String, openToChat: Bool) {
        state.withLock { $0.calls.profiles.append("\(name)|\(status)|\(openToChat)") }
        var own = stores.ownProfile.load()
        own.name = name
        own.status = status
        own.openToChat = openToChat
        stores.ownProfile.save(own)
    }

    /// Keeps the photo and names it in our profile, as the engine does.
    func setAvatar(_ jpeg: [UInt8]?) {
        let hash = jpeg.map { BlobHash(of: $0) }
        state.withLock { $0.calls.avatars.append(hash) }
        if let jpeg, let hash {
            stores.blobs.insert(jpeg, hash: hash, mime: "image/jpeg", storedAt: 0)
        }
        var own = stores.ownProfile.load()
        own.avatarHash = hash
        stores.ownProfile.save(own)
    }

    func createGroup(with others: [NodeId]) -> GroupRecord? {
        state.withLock { $0.calls.groups.append("create \(others.map(\.string).joined(separator: ","))") }
        guard !others.isEmpty else {
            return nil
        }
        let members = (others + [nodeId]).map(\.string)
        let group = GroupRecord(
            id: GroupId.derive(members), createdBy: nodeId.string, createdAt: clock, roster: members.map { GroupMember(nodeId: $0) })
        stores.groups.save(group)
        stores.messages.save(StatusNotices.groupCreated(group.id, by: nodeId, at: clock))
        return group
    }

    func sendGroupMessage(_ text: String, to groupId: String, photo: OutgoingPhoto?, replyTo: MessageReply?) -> MessageRecord? {
        state.withLock { $0.calls.groups.append("send \(groupId): \(text)") }
        guard stores.groups.group(groupId)?.hasLeft == false else {
            return nil
        }
        return store(text, to: nil, in: groupId, photo: photo, replyTo: replyTo)
    }

    func renameGroup(_ groupId: String, to name: String) -> GroupRecord? {
        state.withLock { $0.calls.groups.append("rename \(groupId): \(name)") }
        guard var group = stores.groups.group(groupId), let normalized = TextLimits.outgoingGroupName(name) else {
            return nil
        }
        group.name = normalized
        group.nameUpdatedAt = clock
        stores.groups.save(group)
        return group
    }

    func leaveGroup(_ groupId: String) -> Bool {
        state.withLock { $0.calls.groups.append("leave \(groupId)") }
        guard var group = stores.groups.group(groupId), !group.hasLeft else {
            return false
        }
        stores.messages.deleteMessages(in: groupId, at: clock)
        group.hasLeft = true
        stores.groups.save(group)
        return true
    }

    func deleteMessage(_ id: String) -> Bool {
        state.withLock { $0.calls.deleted.append("message \(id)") }
        return stores.deleteMessage(id, at: clock, me: nodeId)
    }

    func deleteChat(_ conversationId: String) -> Bool {
        state.withLock { $0.calls.deleted.append("chat \(conversationId)") }
        return stores.deleteChat(conversationId, at: clock, me: nodeId)
    }

    func react(to messageId: String, with emoji: String) -> ReactionRecord? {
        state.withLock { $0.calls.reactions.append("\(messageId) \(emoji)") }
        return stores.react(to: messageId, with: emoji, at: clock, me: nodeId)
    }

    func setVerified(_ peer: NodeId, _ verified: Bool) {
        state.withLock { $0.calls.verified.append("\(peer): \(verified)") }
        if var record = stores.peers.peer(peer) {
            record.verified = verified
            stores.peers.upsert(record)
        }
    }

    func block(_ peer: NodeId) {
        state.withLock { $0.calls.blocked.append("block \(peer)") }
        stores.blocks.block(peer, deviceTag: stores.peers.peer(peer)?.deviceTag)
    }

    func unblock(_ peer: NodeId) {
        state.withLock { $0.calls.blocked.append("unblock \(peer)") }
        stores.blocks.unblock(peer, deviceTag: stores.peers.peer(peer)?.deviceTag)
    }

    private func store(
        _ text: String, to recipient: NodeId?, in group: String? = nil, photo: OutgoingPhoto? = nil, replyTo: MessageReply? = nil
    ) -> MessageRecord {
        let index = state.withLock { state in
            defer { state.next += 1 }
            return state.next
        }
        let record = MessageRecord(
            id: "sent-\(index)",
            senderId: nodeId,
            recipientId: recipient,
            conversationId: Conversations.id(sender: nodeId, recipient: recipient, group: group, me: nodeId),
            body: text,
            sentAt: clock + Int64(index),
            pendingKey: recipient.map { stores.peers.peer($0) == nil } ?? false,
            attachment: photo.map { keep($0) },
            replyTo: replyTo
        )
        stores.messages.save(record)
        return record
    }

    /// Keeps a sent photo under its hash, as the engine keeps a room post's, and names it.
    private func keep(_ photo: OutgoingPhoto) -> MessageAttachment {
        let hash = BlobHash(of: photo.bytes)
        stores.blobs.insert(photo.bytes, hash: hash, mime: photo.mime, storedAt: clock)
        state.withLock { $0.calls.photos.append(hash) }
        return MessageAttachment(hash: hash, mime: photo.mime, sourceHash: photo.sourceHash)
    }
}

/// A notifier that keeps what it is asked.
final class RecordingNotifier: Notifier {
    private let postedList = Lock<[LocalNotification]>([])
    private let withdrawnList = Lock<[String]>([])

    var posted: [LocalNotification] { postedList.withLock { $0 } }
    var withdrawn: [String] { withdrawnList.withLock { $0 } }

    func post(_ notification: LocalNotification) {
        postedList.withLock { $0.append(notification) }
    }

    func withdraw(threadId: String) {
        withdrawnList.withLock { $0.append(threadId) }
    }
}

/// A notification permission that answers what it is told to.
final class FakePermission: NotificationPermission {
    private let answer = Lock(NotificationAuthorization.notDetermined)
    private let onRequest: NotificationAuthorization

    init(current: NotificationAuthorization = .notDetermined, onRequest: NotificationAuthorization = .allowed) {
        answer.withLock { $0 = current }
        self.onRequest = onRequest
    }

    func authorization() -> NotificationAuthorization {
        answer.withLock { $0 }
    }

    func request() -> NotificationAuthorization {
        answer.withLock { answer in
            if answer == .notDetermined {
                answer = onRequest
            }
            return answer
        }
    }
}

/// A camera that answers what it is told to, and counts what it was asked.
final class FakeCamera: CameraAccess {
    private struct State {
        var answer: CameraAuthorization
        var requests = 0
    }

    private let state: Lock<State>
    private let scans: Bool
    private let onRequest: CameraAuthorization

    init(scans: Bool = true, current: CameraAuthorization = .notDetermined, onRequest: CameraAuthorization = .allowed) {
        state = Lock(State(answer: current))
        self.scans = scans
        self.onRequest = onRequest
    }

    /// How many times it was asked.
    var requests: Int { state.withLock { $0.requests } }

    /// The user changes the answer in the Settings app.
    func change(to answer: CameraAuthorization) {
        state.withLock { $0.answer = answer }
    }

    func canScan() -> Bool {
        scans
    }

    func authorization() -> CameraAuthorization {
        state.withLock { $0.answer }
    }

    func request() -> CameraAuthorization {
        state.withLock { state in
            state.requests += 1
            if state.answer == .notDetermined {
                state.answer = onRequest
            }
            return state.answer
        }
    }
}

/// A session over a fake mesh and in-memory stores, with our own identity and three people to talk to.
@MainActor
struct AppRig {
    static let me = Person(seed: 1)
    static let sam = Person(seed: 2)
    static let priya = Person(seed: 3)
    static let stranger = Person(seed: 4)

    let stores: MeshStores
    let mesh: FakeMesh
    let notifier: RecordingNotifier
    let session: AppSession

    init(radio: RadioState? = nil, screening: TextScreening? = nil, preferences: MemoryPreferences = MemoryPreferences()) {
        stores = MeshStores.inMemory()
        mesh = FakeMesh(nodeId: Self.me.nodeId, stores: stores, radio: radio)
        notifier = RecordingNotifier()
        session = AppSession(
            identity: OwnIdentity(bundle: Self.me.bundle),
            stores: stores,
            mesh: mesh,
            notifier: notifier,
            textScreening: screening,
            preferences: preferences
        )
    }

    var me: NodeId { Self.me.nodeId }
}
