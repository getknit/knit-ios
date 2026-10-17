import Foundation
import KnitMesh
import KnitStore
import KnitStoreSQL
import KnitSync
import KnitWire

/// A message store whose row write can be refused, as a full disk refuses it, and whose row read can fail, as a database
/// that cannot read its file fails it: told to, ``insertIfAbsent(_:)``, ``save(_:)`` or ``contains(_:)`` fails the store unit it runs in
/// and answers the store's fallback, and everything else goes to the store it wraps. `refuse` is how the unit fails: a
/// memory unit is told so (``MemoryTransactor/failCurrentUnit()``), and the database is handed a write SQLite refuses
/// (``StoreKind``), since a trigger needs GRDB, which stays in KnitStoreSQL. Outside a unit only the fallback is left, as
/// `KnitDatabase.read(or:)` leaves it.
final class RefusingMessageStore: MessageStore {
    let held: any MessageStore
    private let refuse: @Sendable () -> Void
    private let refusing = Lock(false)
    private let failingReads = Lock(false)
    private let refusingSaves = Lock(false)
    private let failingThreads = Lock(false)

    init(_ held: any MessageStore, refuse: @escaping @Sendable () -> Void) {
        self.held = held
        self.refuse = refuse
    }

    /// Whether a row write is refused now.
    var refusesRows: Bool {
        get { refusing.withLock { $0 } }
        set { refusing.withLock { $0 = newValue } }
    }

    /// Whether a row read fails now.
    var failsReads: Bool {
        get { failingReads.withLock { $0 } }
        set { failingReads.withLock { $0 = newValue } }
    }

    /// Whether a saved row is refused now: a status line's, such as a rename's in the roster's unit.
    var refusesSaves: Bool {
        get { refusingSaves.withLock { $0 } }
        set { refusingSaves.withLock { $0 = newValue } }
    }

    /// Whether a thread's read fails now, answering no rows, as `SQLMessageStore.messages(in:)` falls back.
    var failsThreadReads: Bool {
        get { failingThreads.withLock { $0 } }
        set { failingThreads.withLock { $0 = newValue } }
    }

    func insertIfAbsent(_ message: MessageRecord) -> Bool {
        guard refusesRows else {
            return held.insertIfAbsent(message)
        }
        refuse()
        return false
    }

    func message(_ id: String) -> MessageRecord? { held.message(id) }
    func contains(_ id: String) -> Bool {
        guard failsReads else {
            return held.contains(id)
        }
        refuse()
        return false
    }

    func save(_ message: MessageRecord) {
        guard refusesSaves else {
            held.save(message)
            return
        }
        refuse()
    }

    func markDelivered(_ id: String) -> Bool { held.markDelivered(id) }
    func pendingKey(to recipient: NodeId) -> [MessageRecord] { held.pendingKey(to: recipient) }
    func pendingKey(in conversationId: String) -> [MessageRecord] { held.pendingKey(in: conversationId) }
    func clearPendingKey(_ id: String) { held.clearPendingKey(id) }
    func conversations(authoredBy author: NodeId) -> Set<String> { held.conversations(authoredBy: author) }
    func senders(in conversationId: String) -> Set<NodeId> { held.senders(in: conversationId) }
    func messages(in conversationId: String) -> [MessageRecord] {
        guard failsThreadReads else {
            return held.messages(in: conversationId)
        }
        refuse()
        return []
    }
    func threadHeads(excludingSenders blocked: Set<NodeId>) -> [MessageRecord] { held.threadHeads(excludingSenders: blocked) }
    func markRead(in conversationId: String) -> Bool { held.markRead(in: conversationId) }
    func unreadCounts(excludingSenders blocked: Set<NodeId>) -> [ExactKey: Int] { held.unreadCounts(excludingSenders: blocked) }
    func deleteMessage(_ id: String, at now: Int64) -> MessageRecord? { held.deleteMessage(id, at: now) }
    func deleteMessages(in conversationId: String, at now: Int64) -> [MessageRecord] { held.deleteMessages(in: conversationId, at: now) }
    func pruneDeleted(before now: Int64) { held.pruneDeleted(before: now) }
    func deletedAttachments() -> [DeletedAttachment] { held.deletedAttachments() }
    func conversationIds() -> Set<String> { held.conversationIds() }
    func attachmentHashes() -> Set<BlobHash> { held.attachmentHashes() }
    func attachmentSenders(among hashes: Set<BlobHash>) -> [BlobHash: NodeId] { held.attachmentSenders(among: hashes) }
    func conversation(ofAttachment hash: BlobHash) -> String? { held.conversation(ofAttachment: hash) }
    func unsizedAttachments(named hash: BlobHash?) -> [MessageAttachment] { held.unsizedAttachments(named: hash) }
    func setAttachmentDimensions(_ hash: BlobHash, to dimensions: PhotoDimensions) -> Bool {
        held.setAttachmentDimensions(hash, to: dimensions)
    }
    func identities(matching bytesHash: BlobHash) -> [MessageAttachment] { held.identities(matching: bytesHash) }
    func sealedCopies(of plainHash: BlobHash) -> [MessageRecord] { held.sealedCopies(of: plainHash) }
    func keyWantingPlainHash(_ hash: BlobHash) -> String? { held.keyWantingPlainHash(hash) }
    func setAttachmentPlainHash(_ hash: BlobHash, to plainHash: BlobHash) -> Bool { held.setAttachmentPlainHash(hash, to: plainHash) }
    func setModeration(_ id: String, to moderation: MessageModeration) -> Bool { held.setModeration(id, to: moderation) }
    func waitingForModeration() -> [MessageRecord] { held.waitingForModeration() }
    func applyReaction(_ reaction: ReactionRecord) -> Bool { held.applyReaction(reaction) }
    func reaction(on messageId: String, by reactor: NodeId) -> ReactionRecord? { held.reaction(on: messageId, by: reactor) }
    func reactions(in conversationId: String) -> [ReactionRecord] { held.reactions(in: conversationId) }
    func pruneOrphanReactions(updatedBefore cutoff: Int64) { held.pruneOrphanReactions(updatedBefore: cutoff) }
}

/// Which stores an engine runs on: the memory ones under a ``MemoryTransactor``, or the SQL ones over one database, whose
/// unit is the database itself (ADR 2026-10.5sk9's P4a amendment).
enum StoreKind: CaseIterable, Sendable {
    case memory
    case sql

    /// Stores of this kind whose message store refuses its row, or fails its row read, when told to, and the refusing
    /// store. `blobs` is the directory the SQL blob store keeps its files in; `failures` hears every error the database
    /// reports.
    func storesRefusingRows(blobs: URL, failures: @escaping @Sendable (any Error) -> Void) throws -> (MeshStores, RefusingMessageStore) {
        try storesRefusingRows(blobs: blobs, failures: failures, custodyLimits: CustodyLimits())
    }

    /// The same, with custody kept under `custodyLimits`, so a test can make its quotas bite.
    func storesRefusingRows(
        blobs: URL, failures: @escaping @Sendable (any Error) -> Void, custodyLimits: CustodyLimits
    ) throws -> (MeshStores, RefusingMessageStore) {
        let refusing = try refusingStores(blobs: blobs, failures: failures, custodyLimits: custodyLimits)
        return (refusing.stores, refusing.messages)
    }

    /// Stores of this kind whose ratchet store refuses its writes when told to, as a full disk does, and the refusing
    /// store: every ratchet open's unit fails then, a ctl frame's included.
    func storesRefusingOpens(blobs: URL, failures: @escaping @Sendable (any Error) -> Void) throws -> (MeshStores, RefusingRatchetWrites) {
        let refusing = try refusingStores(blobs: blobs, failures: failures, custodyLimits: CustodyLimits())
        return (refusing.stores, refusing.ratchet)
    }

    /// Stores of this kind whose peer store fails its row read when told to, and the refusing store: a unit that reads a
    /// pinned row then fails.
    func storesRefusingPeerReads(blobs: URL, failures: @escaping @Sendable (any Error) -> Void) throws -> (MeshStores, RefusingPeerReads) {
        let refusing = try refusingStores(blobs: blobs, failures: failures, custodyLimits: CustodyLimits())
        return (refusing.stores, refusing.peers)
    }

    private func refusingStores(
        blobs: URL, failures: @escaping @Sendable (any Error) -> Void, custodyLimits: CustodyLimits
    ) throws -> RefusingStores {
        switch self {
        case .memory:
            let memory = MeshStores.inMemory(custodyLimits: custodyLimits)
            let transactor = memory.transactor as? MemoryTransactor
            let refuse: @Sendable () -> Void = { transactor?.failCurrentUnit() }
            let messages = RefusingMessageStore(memory.messages, refuse: refuse)
            let ratchet = RefusingRatchetWrites(memory.ratchet, refuse: refuse)
            let peers = RefusingPeerReads(memory.peers, refuse: refuse)
            let stores = MeshStores(
                custody: memory.custody,
                peers: peers,
                messages: messages,
                conversations: memory.conversations,
                blocks: memory.blocks,
                groups: memory.groups,
                ownProfile: memory.ownProfile,
                blobs: memory.blobs,
                ratchet: ratchet,
                groupRatchet: memory.groupRatchet,
                transactor: memory.transactor
            )
            return RefusingStores(stores: stores, messages: messages, ratchet: ratchet, peers: peers)
        case .sql:
            let database = try KnitDatabase.inMemory(failures: failures)
            let groups = SQLGroupStore(database)
            let refuse: @Sendable () -> Void = {
                // A roster naming a member twice breaks its key: the write SQLite refuses, inside the open unit.
                let member = GroupMember(nodeId: "refused")
                groups.save(GroupRecord(id: "g-refused", createdBy: "refused", createdAt: 1, roster: [member, member]))
            }
            let messages = RefusingMessageStore(SQLMessageStore(database), refuse: refuse)
            let ratchet = RefusingRatchetWrites(SQLRatchetStore(database), refuse: refuse)
            let peers = RefusingPeerReads(SQLPeerStore(database), refuse: refuse)
            let stores = MeshStores(
                custody: SQLCustodyStore(database, limits: custodyLimits),
                peers: peers,
                messages: messages,
                conversations: SQLConversationStore(database),
                blocks: SQLBlockStore(database),
                groups: groups,
                ownProfile: SQLOwnProfileStore(database),
                blobs: try SQLBlobStore(database, directory: blobs),
                ratchet: ratchet,
                groupRatchet: SQLGroupRatchetStore(database),
                transactor: database
            )
            return RefusingStores(stores: stores, messages: messages, ratchet: ratchet, peers: peers)
        }
    }
}

/// Stores that refuse when told to, and the three refusing stores in them.
private struct RefusingStores {
    let stores: MeshStores
    let messages: RefusingMessageStore
    let ratchet: RefusingRatchetWrites
    let peers: RefusingPeerReads
}

/// Counts the errors a database reported.
final class ReportedFailures: Sendable {
    private let reported = Lock(0)

    var count: Int { reported.withLock { $0 } }

    @Sendable func record(_: any Error) {
        reported.withLock { $0 += 1 }
    }
}

/// A fresh directory for one test's files, removed by the caller.
func scratchDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "knit-\(name)-\(ProcessInfo.processInfo.globallyUniqueString)")
}
