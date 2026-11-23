public import KnitWire

/// The rows of a thread whose mentions the name rule judges (``MentionVouch``, the paired contract's revision 3): its
/// newest ``size`` counted rows. A counted row is one someone else sent, someone we haven't blocked, whose stored mention
/// list isn't empty, so our own rows and ordinary chatter never push a highlight out, and blocking a flooder brings the
/// honest highlights back (the contract's revision 5). The stored list is what ``MessageMention/carried(_:in:)`` kept,
/// where Android keeps the list as received, so a crafted list whose tokens aren't in the body counts there and not here
/// (the contract's revision 4). Newest is the thread's display order: `sentAt` as stored, which
/// the engine clamps to a few minutes past our clock, then the message id, the greater being newer. Arrival time isn't
/// used, since a bulk of back-dated rows would take the window from current messages.
///
/// The window covers every stored row of the thread, not only those a screen shows.
public enum MentionWindow {
    /// How many counted rows a thread's window holds.
    public static let size = 200

    /// What the window reads of a row.
    public struct Row: Sendable {
        /// The message id.
        public var id: String
        /// The sender's node id.
        public var sender: String
        /// When it was sent, as stored.
        public var sentAt: Int64
        /// How many entries its mention list holds.
        public var mentions: Int

        /// A row.
        public init(id: String, sender: String, sentAt: Int64, mentions: Int) {
            self.id = id
            self.sender = sender
            self.sentAt = sentAt
            self.mentions = mentions
        }
    }

    /// The ids of the counted rows among `rows` that fall outside the window, `me` being our node id and `blocked` the
    /// senders we blocked. Ids compare by their UTF-16 code units, as Kotlin's `compareTo` does, and node ids by their bytes.
    public static func outside(_ rows: [Row], me: String, blocked: Set<ExactKey> = []) -> Set<ExactKey> {
        let ours = ExactKey(me)
        let counted = rows.filter { row in
            let sender = ExactKey(row.sender)
            return row.mentions > 0 && sender != ours && !blocked.contains(sender)
        }
        guard counted.count > size else {
            return []
        }
        let newestFirst = counted.sorted { first, second in
            first.sentAt != second.sentAt ? first.sentAt > second.sentAt : second.id.utf16.lexicographicallyPrecedes(first.id.utf16)
        }
        return Set(newestFirst.dropFirst(size).map { ExactKey($0.id) })
    }
}
