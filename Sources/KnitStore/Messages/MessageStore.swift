import KnitSync
public import KnitWire

/// What a thread row is (`MessageEntity.kind`, `MessageEntity.kt:225-277`): an ordinary message, or a status line
/// this node wrote about an event, such as a member leaving a group.
///
/// The codes are knit-next's, and never leave this phone. Anything but ``message`` is a notice, including a code
/// this build has no words for, which a newer build may have written. Reading one never fails, because one row
/// that failed would empty a whole thread (ADR 2026-09.n393).
public struct MessageKind: RawRepresentable, Hashable, Sendable, ExpressibleByIntegerLiteral {
    /// An ordinary message (`KIND_NORMAL`).
    public static let message: Self = 0
    /// A member left a group by their own signed `groupleave` (`KIND_MEMBER_LEFT`).
    public static let memberLeft: Self = 1
    /// A member renamed a group; the row's body is the new name (`KIND_GROUP_RENAMED`).
    public static let groupRenamed: Self = 4
    /// A group was created (`KIND_GROUP_CREATED`).
    public static let groupCreated: Self = 6
    /// A member who left came back by a frame of their own (`KIND_MEMBER_REJOINED`).
    public static let memberRejoined: Self = 9

    /// The stored code.
    public let rawValue: Int

    /// Wraps a stored code, known or not.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// A code written out, for the registry above.
    public init(integerLiteral value: Int) {
        self.init(rawValue: value)
    }

    /// Whether the row is a status line rather than a message: never a preview, never acknowledged, and never what
    /// makes someone a sender in a thread (`isStatusNotice`).
    public var isNotice: Bool { self != .message }
}

/// A message in a thread (`MessageEntity` in knit-next, the fields this port reads): ours, one delivered to us, or
/// a status line about an event (``kind``).
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
    /// Ours only: waiting for a key, sealed and sent once one pins. A DM waits for its recipient's, and a group
    /// message for any member's.
    public var pendingKey: Bool
    /// A message, or a status line. For a status line, ``senderId`` is whom the event is about.
    public var kind: MessageKind

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
        pendingKey: Bool = false,
        kind: MessageKind = .message
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
        self.kind = kind
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

    /// Our messages in the thread `conversationId` still waiting for a key, oldest first: a group's.
    func pendingKey(in conversationId: String) -> [MessageRecord]

    /// Clears `id`'s pending-key flag once it has been sealed and sent.
    func clearPendingKey(_ id: String)

    /// The threads `author` has written in: part of what makes a thread accepted rather than a request. A status
    /// line counts, as on Android (`MessageDao.kt:294`), so the creator's own "created" line accepts a group.
    func conversations(authoredBy author: NodeId) -> Set<String>

    /// Who wrote an ordinary message in `conversationId`; status lines never count (`MessageDao.sendersIn`). A group
    /// is accepted when one of them is someone we know.
    func senders(in conversationId: String) -> Set<NodeId>

    /// A thread's messages in reading order: by `sentAt`, ties in the order they were stored.
    func messages(in conversationId: String) -> [MessageRecord]

    /// The newest message of every thread, newest thread first: what a list row shows for its thread
    /// (`observeNewestPerConversation` in knit-next). A thread's newest is the last in its reading order, and a
    /// status line is never one, so a thread of nothing but status lines has no head.
    func threadHeads() -> [MessageRecord]

    /// Removes every row of `conversationId`, status lines included: what leaving a group does to its thread.
    func deleteMessages(in conversationId: String)
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

    private let state = Lock(State())

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

    public func threadHeads() -> [MessageRecord] {
        state.withLock { state in
            var heads: [ExactKey: Row] = [:]
            for row in state.rows.values where !row.record.kind.isNotice {
                let thread = ExactKey(row.record.conversationId)
                if let head = heads[thread], State.precedes(row, head) {
                    continue
                }
                heads[thread] = row
            }
            return heads.values.sorted { State.precedes($1, $0) }.map(\.record)
        }
    }

    public func deleteMessages(in conversationId: String) {
        let thread = ExactKey(conversationId)
        state.withLock { state in
            state.rows = state.rows.filter { ExactKey($0.value.record.conversationId) != thread }
        }
    }
}
