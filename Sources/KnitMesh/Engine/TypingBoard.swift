import KnitWire

/// Who is typing where (`TypingTracker` in knit-next): each sender's cue in a thread holds for a while, every cue from
/// them pushes the end out, and a message from them ends it at once. It lives in memory only, outside custody, and a
/// link going down leaves it be, as Android's does: the cue lapses on its own.
///
/// Synchronous and kept as deadlines on the monotonic clock, like every other timer the engine keeps (ADR 2026-09.gq84).
internal struct TypingBoard {
    /// The most (thread, sender) pairs held at once (`TYPING_CAP`, `TypingTracker.kt:114`). A new pair past it is
    /// ignored; a pair already held always takes its refresh.
    static let capacity = 64

    private struct Key: Hashable {
        var thread: ExactKey
        var sender: NodeId
    }

    private struct Cue {
        var thread: String
        var lapsesAt: Int64
    }

    private var cues: [Key: Cue] = [:]

    /// How many pairs are held.
    var count: Int { cues.count }

    /// When the next cue lapses, or `nil` while nobody is typing.
    var nextDeadline: Int64? { cues.values.map(\.lapsesAt).min() }

    /// Who is typing in each thread, each thread's senders in node id order. Every thread named here is one the engine
    /// spelled itself (the room, a node id, a held group's id), so two never differ only in how their text normalizes.
    var picture: [String: [NodeId]] {
        var typing: [String: [NodeId]] = [:]
        for (key, cue) in cues {
            typing[cue.thread, default: []].append(key.sender)
        }
        return typing.mapValues { $0.sorted() }
    }

    /// `sender` is typing in `thread` until `lapsesAt` (`TypingTracker.onTyping`). Answers whether who is typing changed:
    /// a refresh only moves the end, and a new pair past ``capacity`` is ignored.
    mutating func note(_ sender: NodeId, in thread: String, until lapsesAt: Int64) -> Bool {
        let key = Key(thread: ExactKey(thread), sender: sender)
        if cues[key] != nil {
            cues[key]?.lapsesAt = lapsesAt
            return false
        }
        guard cues.count < Self.capacity else {
            return false
        }
        cues[key] = Cue(thread: thread, lapsesAt: lapsesAt)
        return true
    }

    /// `sender`'s message landed in `thread`, so their cue there ends now (`TypingTracker.onMessageFrom`). Answers whether
    /// one was held.
    mutating func clear(_ sender: NodeId, in thread: String) -> Bool {
        cues.removeValue(forKey: Key(thread: ExactKey(thread), sender: sender)) != nil
    }

    /// Ends every cue due by `now`, and answers whether any was.
    mutating func lapse(now: Int64) -> Bool {
        let before = cues.count
        cues = cues.filter { $0.value.lapsesAt > now }
        return cues.count != before
    }

    /// Forgets every cue, and answers whether any was held.
    mutating func removeAll() -> Bool {
        defer { cues.removeAll() }
        return !cues.isEmpty
    }
}
