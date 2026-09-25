public import KnitWire

/// The delivery ticks this node owes the authors of room posts it received (`AckSync.kt`, its cleartext arm).
///
/// A DM's receipt floods and is carried, so it finds its way home. A room post has no single recipient, so its
/// tick is lighter: a signed, point-to-point receipt with no `sentAt` and a fresh id each time, sent only over a
/// live link to the author, and never carried. This build cannot seal, so every tick takes that cleartext form.
/// A tick owed to an author with no link waits for one, for up to 24 hours. Times are on the monotonic clock.
public struct AckSync: Sendable {
    /// How long an owed tick waits for a link (`OWED_TTL_MS`).
    public static let defaultOwedMilliseconds: Int64 = 86_400_000
    /// The most ticks owed at once, oldest evicted first (`OWED_CAP`).
    public static let defaultCapacity = 500

    private struct Owed: Sendable {
        var messageId: String
        var author: NodeId
        var recordedAt: Int64
    }

    private let owedMilliseconds: Int64
    private let capacity: Int
    /// Oldest first.
    private var owed: [Owed] = []

    /// A ledger with knit-next's bounds unless told otherwise.
    public init(owedMilliseconds: Int64 = Self.defaultOwedMilliseconds, capacity: Int = Self.defaultCapacity) {
        self.owedMilliseconds = owedMilliseconds
        self.capacity = capacity
    }

    /// How many ticks are owed.
    public var count: Int { owed.count }

    /// Whether no tick is owed.
    public var isEmpty: Bool { owed.isEmpty }

    /// We delivered room post `messageId` by `author`. Answers whether to tick it now, over the live link to the
    /// author; otherwise the tick is owed until a link comes up. Our own posts are never ticked, and a re-served
    /// post owed already stays owed once.
    public mutating func owe(_ messageId: String, author: NodeId, me: NodeId, authorLinked: Bool, now: Int64) -> Bool {
        guard author != me else {
            return false
        }
        sweep(now: now)
        let key = ExactKey(messageId)
        let existing = owed.firstIndex { ExactKey($0.messageId) == key }
        if authorLinked {
            if let existing {
                owed.remove(at: existing)
            }
            return true
        }
        if existing == nil {
            if owed.count >= capacity {
                owed.removeFirst()
            }
            owed.append(Owed(messageId: messageId, author: author, recordedAt: now))
        }
        return false
    }

    /// A link to `author` is up: the ids of the ticks owed to it, oldest first, which the caller sends now.
    public mutating func linked(to author: NodeId, now: Int64) -> [String] {
        sweep(now: now)
        let due = owed.filter { $0.author == author }.map(\.messageId)
        owed.removeAll { $0.author == author }
        return due
    }

    /// Drops ticks owed longer than the window.
    public mutating func sweep(now: Int64) {
        owed.removeAll { now - $0.recordedAt > owedMilliseconds }
    }
}
