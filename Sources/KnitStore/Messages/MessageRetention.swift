public import KnitWire

/// One stored row as retention weighs it (`ConversationActivity` and the columns `MessageDao`'s retention deletes order
/// by, `MessageDao.kt:724-781` at knit-next `e63f15f4`): its id, its thread, who it is from, its stored `sentAt` and its
/// kind. A status line counts as a row, as Kotlin's `countIn` counts notices.
public struct RetentionRow: Sendable, Equatable {
    /// The row's id: a message's frame id, or a status line's own.
    public var id: String
    /// The thread it is in (``Conversations``).
    public var conversationId: String
    /// Who sent it, or for a status line whom it is about.
    public var senderId: NodeId
    /// Its stored `sentAt`, clamped on the way in as every row's is.
    public var sentAt: Int64
    /// A message, or a status line.
    public var kind: MessageKind

    /// Describes row `id` of `kind` in thread `conversationId`, from `senderId` at `sentAt`.
    public init(id: String, conversationId: String, senderId: NodeId, sentAt: Int64, kind: MessageKind = .message) {
        self.id = id
        self.conversationId = conversationId
        self.senderId = senderId
        self.sentAt = sentAt
        self.kind = kind
    }
}

/// What a ``MessageStore`` reads and writes for retention (knit-ios #21), apart so the store's protocol stays inside the
/// lint's length.
public protocol MessageRetaining: AnyObject, Sendable {
    /// The rows of the threads `conversationIds` names, by their ids' bytes, as retention weighs them, in no order
    /// (``MessageRetention``). A read that fails answers none.
    func retentionRows(in conversationIds: Set<String>) -> [RetentionRow]

    /// Removes the rows `ids` at `now` as retention trims them, and answers what it removed (knit-ios #21). Each ordinary
    /// message a carrier could still re-serve, its clock behind ours by up to a TTL included, is remembered with no photo,
    /// in the same transaction, for one TTL of its thread from the later of its `sentAt` and the trim
    /// (``DeletedMessages/trimmedExpiry(sentAt:kind:conversationId:at:limits:)``). Reactions stay for the orphan sweep, as
    /// Android's retention leaves them. A write that fails removes nothing and answers none.
    @discardableResult
    func trimMessages(_ ids: [String], at now: Int64) -> [MessageRecord]
}

/// Which rows the local retention sweep removes (`MessageRepository.sweepRetention`, `MessageRepository.kt:354-414` at
/// knit-next `e63f15f4`, run from `MeshManager.sweepLocalStorage`, `MeshManager.kt:2991-3012`, at start and every ten
/// minutes). It bounds the two threads a stranger can grow for free: the Nearby room, and the message requests a fork
/// opens with every identity it mints (knit-ios #21).
///
/// Local only, like a delete (ADR 2026-10.u7cq): it reads the rows, never custody, and nothing on the wire or in the
/// digest reads what it removed. The numbers are Kotlin's defaults. Rows are ordered as Kotlin's deletes order them, by
/// `sentAt` and then by the id's bytes, which is SQLite's BINARY order, so two phones holding the same rows remove the
/// same ones.
public enum MessageRetention {
    /// The most rows the room keeps (`DEFAULT_NEARBY_MAX_MESSAGES`, `:396`).
    public static let roomMaxMessages = 2000
    /// A room row older than this goes whatever the count: 30 days (`DEFAULT_NEARBY_MAX_AGE_MS`, `:399`).
    public static let roomMaxAgeMilliseconds: Int64 = 2_592_000_000
    /// The newest rows each stranger keeps in the room, custody's per-sender quota (`DEFAULT_ROOM_MAX_PER_STRANGER`, `:405`).
    public static let roomMaxPerStranger = 200
    /// The newest rows a message request keeps (`DEFAULT_MAX_PER_PENDING_THREAD`, `:408`).
    public static let maxPerPendingThread = 50
    /// A message request whose newest row is older than this goes whole: 7 days (`DEFAULT_PENDING_THREAD_MAX_AGE_MS`, `:411`).
    public static let pendingThreadMaxAgeMilliseconds: Int64 = 604_800_000
    /// The most message requests kept, the most recently active first (`DEFAULT_MAX_PENDING_THREADS`, `:414`).
    public static let maxPendingThreads = 100

    /// The rows to remove at `now`: from `room`, the Nearby room's rows, with `knows` telling the people the user talks to
    /// from strangers (Kotlin's `knownSenders`), and from `pending`, the rows of every thread that is neither the room nor
    /// protected (accepted, verified, written in, or a group a known peer posted in, `MeshManager.kt:2996-3008`).
    ///
    /// In a group request the two count trims keep each sender's newest message, rename or rejoin row, which
    /// `GroupRoster.actedAfter` reads when a leave is replayed from custody (ADR 2026-10.5sk9's phase P7a): without it, a
    /// replayed leave whose first verdict a failed unit lost would depart a member who had since posted. Kotlin replays no
    /// leave, so it trims them. The 7-day delete takes them too: custody carries a leave for at most a day past its
    /// `sentAt`, so a row a week old can never be newer than a leave still there to replay.
    public static func trims(room: [RetentionRow], pending: [RetentionRow], now: Int64, knows: (NodeId) -> Bool) -> [RetentionRow] {
        roomTrims(room, now: now, knows: knows) + pendingTrims(pending, now: now)
    }

    /// The room's rule, in Kotlin's order: the 30-day cut, each stranger's newest 200, then over 2,000 strangers' oldest
    /// first, and last the oldest of anyone down to 2,000 (`:360-366`).
    static func roomTrims(_ rows: [RetentionRow], now: Int64, knows: (NodeId) -> Bool) -> [RetentionRow] {
        let cutoff = now &- roomMaxAgeMilliseconds
        var trimmed = rows.filter { $0.sentAt < cutoff }
        var kept: [RetentionRow] = []
        for posts in Dictionary(grouping: rows.filter { $0.sentAt >= cutoff }, by: \.senderId).values {
            guard posts.count > roomMaxPerStranger, let sender = posts.first?.senderId, !knows(sender) else {
                kept += posts
                continue
            }
            let newest = posts.sorted { precedes($1, $0) }
            kept += newest.prefix(roomMaxPerStranger)
            trimmed += newest.dropFirst(roomMaxPerStranger)
        }
        var oldest = kept.sorted(by: precedes)
        var over = oldest.count - roomMaxMessages
        if over > 0 {
            oldest = oldest.filter { row in
                guard over > 0, !knows(row.senderId) else {
                    return true
                }
                over -= 1
                trimmed.append(row)
                return false
            }
        }
        // The last resort: a room over its count on known senders alone.
        trimmed += oldest.dropLast(roomMaxMessages)
        return trimmed
    }

    /// The requests' rule, in Kotlin's order: a thread a week quiet goes whole, any other keeps its newest 50, and past 100
    /// threads the least recently active go (`:368-388`). Ties in activity keep the thread whose id's bytes come first,
    /// as Kotlin's stable sort keeps `GROUP BY`'s order.
    static func pendingTrims(_ rows: [RetentionRow], now: Int64) -> [RetentionRow] {
        let cutoff = now &- pendingThreadMaxAgeMilliseconds
        var trimmed: [RetentionRow] = []
        var live: [(last: RetentionRow, kept: [RetentionRow])] = []
        for thread in Dictionary(grouping: rows, by: { ExactKey($0.conversationId) }).values {
            let newest = thread.sorted { precedes($1, $0) }
            guard let last = newest.first, last.sentAt >= cutoff else {
                trimmed += newest
                continue
            }
            let (kept, cut) = keepingNewest(maxPerPendingThread, of: newest)
            trimmed += cut
            live.append((last, kept))
        }
        guard live.count > maxPendingThreads else {
            return trimmed
        }
        let active = live.sorted { first, second in
            guard first.last.sentAt == second.last.sentAt else {
                return first.last.sentAt > second.last.sentAt
            }
            return first.last.conversationId.utf8.lexicographicallyPrecedes(second.last.conversationId.utf8)
        }
        for thread in active.dropFirst(maxPendingThreads) {
            trimmed += keepingNewest(0, of: thread.kept).cut
        }
        return trimmed
    }

    /// Splits `newest`, one thread's rows newest first, into the newest `count` and the rest, keeping back in a group each
    /// sender's newest row that a replayed leave reads (``GroupRoster``'s `actedAfter`, in KnitMesh).
    static func keepingNewest(_ count: Int, of newest: [RetentionRow]) -> (kept: [RetentionRow], cut: [RetentionRow]) {
        var anchored: Set<NodeId> = []
        var kept: [RetentionRow] = []
        var cut: [RetentionRow] = []
        for (index, row) in newest.enumerated() {
            let anchors = Conversations.isGroup(row.conversationId) && Self.anchors(row.kind) && anchored.insert(row.senderId).inserted
            if index < count || anchors {
                kept.append(row)
            } else {
                cut.append(row)
            }
        }
        return (kept, cut)
    }

    /// Whether a row of `kind` shows its sender acting in a group: a message, a rename or a rejoin.
    static func anchors(_ kind: MessageKind) -> Bool {
        kind == .message || kind == .groupRenamed || kind == .memberRejoined
    }

    /// Whether `lhs` is older than `rhs`: the older `sentAt`, then the id's bytes, as SQLite's BINARY collation orders
    /// `ORDER BY sentAt, id`.
    static func precedes(_ lhs: RetentionRow, _ rhs: RetentionRow) -> Bool {
        guard lhs.sentAt == rhs.sentAt else {
            return lhs.sentAt < rhs.sentAt
        }
        return lhs.id.utf8.lexicographicallyPrecedes(rhs.id.utf8)
    }
}
