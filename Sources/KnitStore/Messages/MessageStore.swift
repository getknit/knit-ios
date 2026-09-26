public import KnitWire
import Synchronization

/// A message in a thread (`MessageEntity` in knit-next, the fields the MVP reads): ours, or one delivered to us.
public struct MessageRecord: Sendable, Equatable {
    /// The frame id, which a receipt acknowledges.
    public var id: String
    /// The author.
    public var senderId: NodeId
    /// The recipient, for a DM; `nil` for a room post.
    public var recipientId: NodeId?
    /// The thread (``Conversations``).
    public var conversationId: String
    /// The text, at most 2000 UTF-16 units.
    public var body: String
    /// The author's clock, clamped to five minutes past ours on the way in, so a far-future post cannot pin
    /// itself to the top of a thread.
    public var sentAt: Int64
    /// When it reached us by our own clock, or `nil` for our own message.
    public var arrivedAt: Int64?
    /// Ours only: a receipt came back. For a DM that means its recipient has it; for a room post, that someone
    /// does.
    public var delivered: Bool
    /// Ours only: a DM waiting for its recipient's key, sealed and sent once their profile pins.
    public var pendingKey: Bool

    /// Makes a record.
    public init(
        id: String,
        senderId: NodeId,
        recipientId: NodeId?,
        conversationId: String,
        body: String,
        sentAt: Int64,
        arrivedAt: Int64? = nil,
        delivered: Bool = false,
        pendingKey: Bool = false
    ) {
        self.id = id
        self.senderId = senderId
        self.recipientId = recipientId
        self.conversationId = conversationId
        self.body = body
        self.sentAt = sentAt
        self.arrivedAt = arrivedAt
        self.delivered = delivered
        self.pendingKey = pendingKey
    }
}

/// The message threads (`MessageRepository` in knit-next).
public protocol MessageStore: AnyObject, Sendable {
    /// The message `id`, or `nil`.
    func message(_ id: String) -> MessageRecord?

    /// Whether `id` is held: the gate that keeps a re-served frame from notifying twice.
    func contains(_ id: String) -> Bool

    /// Stores `message` unless its id is held, and answers whether it did. A re-served frame carries the same
    /// signed bytes, so it can never say anything new.
    @discardableResult
    func insertIfAbsent(_ message: MessageRecord) -> Bool

    /// Stores `message`, replacing any row with its id.
    func save(_ message: MessageRecord)

    /// Marks our message `id` delivered, and answers whether that changed anything.
    @discardableResult
    func markDelivered(_ id: String) -> Bool

    /// Our DMs to `recipient` still waiting for their key, oldest first.
    func pendingKey(to recipient: NodeId) -> [MessageRecord]

    /// Clears `id`'s pending-key flag once it has been sealed and sent.
    func clearPendingKey(_ id: String)

    /// The threads `author` has written in: part of what makes a DM accepted rather than a request.
    func conversations(authoredBy author: NodeId) -> Set<String>

    /// A thread's messages in reading order: by `sentAt`, ties in the order they were stored.
    func messages(in conversationId: String) -> [MessageRecord]

    /// The newest message of every thread, newest thread first: what a list row shows for its thread
    /// (`observeNewestPerConversation` in knit-next). A thread's newest is the last in its reading order.
    func threadHeads() -> [MessageRecord]
}

/// A ``MessageStore`` in memory, keyed by the ids' bytes (``ExactKey``) and safe to share across threads.
public final class MemoryMessageStore: MessageStore {
    private struct Row: Sendable {
        var record: MessageRecord
        /// When it was first stored, which breaks ties in `sentAt`.
        let order: Int
    }

    private struct State: Sendable {
        var rows: [ExactKey: Row] = [:]
        var nextOrder = 0

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
    }

    private let state = Mutex(State())

    /// An empty store.
    public init() {
        // Nothing to set up.
    }

    public func message(_ id: String) -> MessageRecord? {
        state.withLock { $0.rows[ExactKey(id)]?.record }
    }

    public func contains(_ id: String) -> Bool {
        state.withLock { $0.rows[ExactKey(id)] != nil }
    }

    @discardableResult
    public func insertIfAbsent(_ message: MessageRecord) -> Bool {
        state.withLock { state in
            guard state.rows[ExactKey(message.id)] == nil else {
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

    public func clearPendingKey(_ id: String) {
        state.withLock { $0.rows[ExactKey(id)]?.record.pendingKey = false }
    }

    public func conversations(authoredBy author: NodeId) -> Set<String> {
        state.withLock { Set($0.rows.values.map(\.record).filter { $0.senderId == author }.map(\.conversationId)) }
    }

    public func messages(in conversationId: String) -> [MessageRecord] {
        state.withLock { state in
            state.inReadingOrder { $0.conversationId == conversationId }
        }
    }

    public func threadHeads() -> [MessageRecord] {
        state.withLock { state in
            var heads: [ExactKey: Row] = [:]
            for row in state.rows.values {
                let thread = ExactKey(row.record.conversationId)
                if let head = heads[thread], State.precedes(row, head) {
                    continue
                }
                heads[thread] = row
            }
            return heads.values.sorted { State.precedes($1, $0) }.map(\.record)
        }
    }
}
