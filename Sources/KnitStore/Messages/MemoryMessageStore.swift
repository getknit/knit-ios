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

    private struct State: Sendable {
        var rows: [ExactKey: Row] = [:]
        var nextOrder = 0
        /// The deleted ordinary messages, by id.
        var deleted: [ExactKey: Deleted] = [:]

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
        let key = ExactKey(id)
        return state.withLock { state in
            guard let row = state.rows.removeValue(forKey: key) else {
                return nil
            }
            state.remember(row.record, deletedAt: now)
            return row.record
        }
    }

    @discardableResult
    public func deleteMessages(in conversationId: String, at now: Int64) -> [MessageRecord] {
        let thread = ExactKey(conversationId)
        return state.withLock { state in
            let removed = state.inReadingOrder { ExactKey($0.conversationId) == thread }
            for record in removed {
                state.rows[ExactKey(record.id)] = nil
                state.remember(record, deletedAt: now)
            }
            return removed
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
}
