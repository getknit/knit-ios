import KnitSync
public import KnitWire

/// A ``MessageStore`` in memory, keyed by the ids' bytes (``ExactKey``) and safe to share across threads.
public final class MemoryMessageStore: MessageStore {
    private struct Row: Sendable {
        var record: MessageRecord
        /// When it was first stored, which breaks ties in `sentAt`.
        let order: Int
    }

    /// A deleted ordinary message: its id, when that may be forgotten, and the photo it carried.
    private struct Deleted: Sendable {
        let id: String
        let expiresAt: Int64
        let attachment: BlobHash?
    }

    /// A reaction's key: its message's id by its bytes, and who reacted.
    private struct ReactionKey: Hashable, Sendable {
        let message: ExactKey
        let reactor: NodeId
    }

    private struct State: Sendable {
        var rows: [ExactKey: Row] = [:]
        var nextOrder = 0
        /// The deleted ordinary messages, by id.
        var deleted: [ExactKey: Deleted] = [:]
        /// Every reaction held, retractions and those whose message is not held included.
        var reactions: [ReactionKey: ReactionRecord] = [:]

        mutating func put(_ message: MessageRecord) {
            let key = ExactKey(message.id)
            if let existing = rows[key] {
                rows[key] = Row(record: message, order: existing.order)
            } else {
                rows[key] = Row(record: message, order: nextOrder)
                nextOrder += 1
            }
        }

        /// The rows `isIncluded` picks, in reading order: `sentAt`, then the order stored.
        func inReadingOrder(where isIncluded: (MessageRecord) -> Bool) -> [MessageRecord] {
            rows.values
                .filter { isIncluded($0.record) }
                .sorted(by: Self.precedes)
                .map(\.record)
        }

        /// Whether `first` reads before `second` in a thread.
        static func precedes(_ first: Row, _ second: Row) -> Bool {
            (first.record.sentAt, first.order) < (second.record.sentAt, second.order)
        }

        /// Remembers deleted `record`'s id, unless it is a status line, keeping the later of two expiries.
        mutating func remember(_ record: MessageRecord, deletedAt now: Int64) {
            guard !record.kind.isNotice else {
                return
            }
            let key = ExactKey(record.id)
            let expiry = DeletedMessages.expiry(sentAt: record.sentAt, deletedAt: now)
            let held = deleted[key]
            deleted[key] = Deleted(
                id: record.id, expiresAt: max(held?.expiresAt ?? expiry, expiry), attachment: record.attachment?.hash ?? held?.attachment)
        }

        /// Removes the row `key` and its reactions, and remembers its id: one delete.
        mutating func remove(_ key: ExactKey, deletedAt now: Int64) -> MessageRecord? {
            guard let row = rows.removeValue(forKey: key) else {
                return nil
            }
            reactions = reactions.filter { $0.key.message != key }
            remember(row.record, deletedAt: now)
            return row.record
        }
    }

    private let state = Lock(State())

    /// An empty store.
    public init() {
        // Nothing to set up.
    }

    public func message(_ id: String) -> MessageRecord? {
        state.withLock { $0.rows[ExactKey(id)]?.record }
    }

    public func contains(_ id: String) -> Bool {
        let key = ExactKey(id)
        return state.withLock { $0.rows[key] != nil || $0.deleted[key] != nil }
    }

    @discardableResult
    public func insertIfAbsent(_ message: MessageRecord) -> Bool {
        let key = ExactKey(message.id)
        return state.withLock { state in
            guard state.rows[key] == nil, state.deleted[key] == nil else {
                return false
            }
            state.put(message)
            return true
        }
    }

    public func save(_ message: MessageRecord) {
        state.withLock { $0.put(message) }
    }

    @discardableResult
    public func markDelivered(_ id: String) -> Bool {
        state.withLock { state in
            let key = ExactKey(id)
            guard let row = state.rows[key], !row.record.delivered else {
                return false
            }
            state.rows[key]?.record.delivered = true
            return true
        }
    }

    public func pendingKey(to recipient: NodeId) -> [MessageRecord] {
        state.withLock { state in
            state.inReadingOrder { $0.pendingKey && $0.recipientId == recipient }
        }
    }

    public func pendingKey(in conversationId: String) -> [MessageRecord] {
        let thread = ExactKey(conversationId)
        return state.withLock { state in
            state.inReadingOrder { $0.pendingKey && ExactKey($0.conversationId) == thread }
        }
    }

    public func clearPendingKey(_ id: String) {
        state.withLock { $0.rows[ExactKey(id)]?.record.pendingKey = false }
    }

    public func conversations(authoredBy author: NodeId) -> Set<String> {
        state.withLock { Set($0.rows.values.map(\.record).filter { $0.senderId == author }.map(\.conversationId)) }
    }

    public func senders(in conversationId: String) -> Set<NodeId> {
        let thread = ExactKey(conversationId)
        return state.withLock { state in
            Set(state.rows.values.map(\.record).filter { !$0.kind.isNotice && ExactKey($0.conversationId) == thread }.map(\.senderId))
        }
    }

    public func messages(in conversationId: String) -> [MessageRecord] {
        state.withLock { state in
            state.inReadingOrder { $0.conversationId == conversationId }
        }
    }

    public func threadHeads(excludingSenders blocked: Set<NodeId>) -> [MessageRecord] {
        state.withLock { state in
            var heads: [ExactKey: Row] = [:]
            for row in state.rows.values where !row.record.kind.isNotice && !blocked.contains(row.record.senderId) {
                let thread = ExactKey(row.record.conversationId)
                if let head = heads[thread], State.precedes(row, head) {
                    continue
                }
                heads[thread] = row
            }
            return heads.values.sorted { State.precedes($1, $0) }.map(\.record)
        }
    }

    @discardableResult
    public func deleteMessage(_ id: String, at now: Int64) -> MessageRecord? {
        state.withLock { $0.remove(ExactKey(id), deletedAt: now) }
    }

    @discardableResult
    public func deleteMessages(in conversationId: String, at now: Int64) -> [MessageRecord] {
        let thread = ExactKey(conversationId)
        return state.withLock { state in
            state.inReadingOrder { ExactKey($0.conversationId) == thread }.compactMap { state.remove(ExactKey($0.id), deletedAt: now) }
        }
    }

    public func pruneDeleted(before now: Int64) {
        state.withLock { state in
            state.deleted = state.deleted.filter { $0.value.expiresAt >= now }
        }
    }

    public func deletedAttachments() -> [DeletedAttachment] {
        state.withLock { state in
            state.deleted
                .sorted { $0.key.bytes.lexicographicallyPrecedes($1.key.bytes) }
                .compactMap { _, deleted in deleted.attachment.map { DeletedAttachment(id: deleted.id, hash: $0) } }
        }
    }

    public func conversationIds() -> Set<String> {
        state.withLock { Set($0.rows.values.map(\.record.conversationId)) }
    }

    public func attachmentHashes() -> Set<BlobHash> {
        state.withLock { Set($0.rows.values.compactMap(\.record.attachment?.hash)) }
    }

    public func unsizedAttachments(named hash: BlobHash?) -> [MessageAttachment] {
        state.withLock { state in
            var seen = Set<BlobHash>()
            return state.rows.values.sorted { $0.order > $1.order }.compactMap(\.record.attachment)
                .filter { $0.dimensions == nil && (hash == nil || $0.hash == hash) && seen.insert($0.hash).inserted }
        }
    }

    @discardableResult
    public func setAttachmentDimensions(_ hash: BlobHash, to dimensions: PhotoDimensions) -> Bool {
        state.withLock { state in
            var changed = false
            for (key, row) in state.rows where row.record.attachment?.hash == hash && row.record.attachment?.dimensions != dimensions {
                state.rows[key]?.record.attachment?.dimensions = dimensions
                changed = true
            }
            return changed
        }
    }

    @discardableResult
    public func setModeration(_ id: String, to moderation: MessageModeration) -> Bool {
        state.withLock { state in
            let key = ExactKey(id)
            guard let row = state.rows[key], row.record.moderation != moderation else {
                return false
            }
            state.rows[key]?.record.moderation = moderation
            return true
        }
    }

    public func waitingForModeration() -> [MessageRecord] {
        state.withLock { state in
            state.rows.values.filter { $0.record.moderation == .waiting }.sorted { $0.order < $1.order }.map(\.record)
        }
    }

    @discardableResult
    public func applyReaction(_ reaction: ReactionRecord) -> Bool {
        let key = ReactionKey(message: ExactKey(reaction.messageId), reactor: reaction.reactor)
        return state.withLock { state in
            guard state.deleted[key.message] == nil else {
                return false
            }
            if let held = state.reactions[key], reaction.updatedAt <= held.updatedAt {
                return false
            }
            state.reactions[key] = reaction
            return true
        }
    }

    public func reaction(on messageId: String, by reactor: NodeId) -> ReactionRecord? {
        state.withLock { $0.reactions[ReactionKey(message: ExactKey(messageId), reactor: reactor)] }
    }

    public func reactions(in conversationId: String) -> [ReactionRecord] {
        let thread = ExactKey(conversationId)
        return state.withLock { state in
            state.reactions
                .filter { key, reaction in
                    guard reaction.emoji != nil, let row = state.rows[key.message] else {
                        return false
                    }
                    return row.record.kind == .message && ExactKey(row.record.conversationId) == thread
                }
                .sorted { first, second in
                    if first.value.updatedAt != second.value.updatedAt {
                        return first.value.updatedAt < second.value.updatedAt
                    }
                    if first.key.message != second.key.message {
                        return first.key.message.bytes.lexicographicallyPrecedes(second.key.message.bytes)
                    }
                    return first.key.reactor.string.utf8.lexicographicallyPrecedes(second.key.reactor.string.utf8)
                }
                .map(\.value)
        }
    }

    public func pruneOrphanReactions(updatedBefore cutoff: Int64) {
        state.withLock { state in
            state.reactions = state.reactions.filter { key, reaction in
                reaction.updatedAt >= cutoff || state.rows[key.message] != nil
            }
        }
    }
}

extension MemoryMessageStore {
    /// Who sent the earliest message carrying each of `hashes` (``MessageStore/attachmentSenders(among:)``).
    public func attachmentSenders(among hashes: Set<BlobHash>) -> [BlobHash: NodeId] {
        state.withLock { state in
            // Earliest first, as the SQL store reads them, so the first message carrying each hash names its sender.
            let carriers = state.rows.values.map(\.record).filter { $0.attachment.map { hashes.contains($0.hash) } ?? false }
            var senders: [BlobHash: NodeId] = [:]
            for record in carriers.sorted(by: Self.precedes) {
                if let hash = record.attachment?.hash, senders[hash] == nil {
                    senders[hash] = record.senderId
                }
            }
            return senders
        }
    }

    /// Whether `lhs` comes before `rhs` by `sentAt` and then by its id's bytes, as SQLite's BINARY collation orders it.
    private static func precedes(_ lhs: MessageRecord, _ rhs: MessageRecord) -> Bool {
        guard lhs.sentAt == rhs.sentAt else {
            return lhs.sentAt < rhs.sentAt
        }
        return Array(lhs.id.utf8).lexicographicallyPrecedes(Array(rhs.id.utf8))
    }
}
