import KnitStore
import KnitWire

/// A thread's lit mentions, kept from one build of it to the next while what judged them stands: the names the labels are
/// made from, a group's roster and the thread's window (knit-ios #36). Judging a list costs a label and its keys for each
/// id it names, so a rebuild that moved none of them judges no row again, and the window (``MentionWindow``) bounds what
/// one that moved them judges. A row's own sender, words and list are checked too, in case they changed.
internal struct MentionLights {
    private var vouch = MentionVouch(labels: .empty)
    /// The roster judged under, and its ids' bytes, which say whether it moved.
    private var members: [String]?
    private var roster: [ExactKey]?
    /// The ids of this build's counted rows outside the thread's window.
    private var outside: Set<ExactKey> = []
    /// The rows this build lit, and those the last one did.
    private var rows: [ExactKey: Row] = [:]
    private var previous: [ExactKey: Row] = [:]

    /// One row as it was judged: its sender, words and list by their bytes, since a span counts code units, whether it
    /// was in the window, and the spans they lit.
    private struct Row {
        var sender: ExactKey
        var body: ExactKey
        var ids: [ExactKey]
        var names: [ExactKey]
        var inWindow: Bool
        var spans: [Range<Int>]

        init(_ message: MessageRecord, inWindow: Bool, spans: [Range<Int>]) {
            sender = ExactKey(message.senderId.string)
            body = ExactKey(message.body)
            ids = message.mentions.map { ExactKey($0.nodeId) }
            names = message.mentions.map { ExactKey($0.name) }
            self.inWindow = inWindow
            self.spans = spans
        }

        func holds(_ message: MessageRecord, inWindow: Bool) -> Bool {
            self.inWindow == inWindow && sender == ExactKey(message.senderId.string) && body == ExactKey(message.body)
                && ids == message.mentions.map { ExactKey($0.nodeId) } && names == message.mentions.map { ExactKey($0.name) }
        }
    }

    /// Starts a build of a thread whose stored rows are `thread`, every one, judged under `labels` and, in a group thread,
    /// `roster`, `me` being our node id and `blocked` the people we blocked, whose rows the window doesn't count. What the
    /// last build lit is kept only while the labels and the roster still stand, and a row whose place in the window moved
    /// is judged again. A row it lit and this one doesn't is let go. The judge's memos keep only what the last build's
    /// rows name.
    mutating func begin(labels: PeerLabelIndex, roster: [String]?, thread: [MessageRecord], me: String, blocked: Set<NodeId>) {
        let ids = roster.map { $0.map(ExactKey.init) }
        vouch.retain(ids: Set(rows.values.flatMap(\.ids)), names: Set(rows.values.flatMap(\.names)))
        if vouch.labels.holdsTheNames(of: labels), self.roster == ids {
            previous = rows
        } else {
            vouch.relabel(labels)
            previous = [:]
        }
        self.roster = ids
        members = roster
        outside = MentionWindow.outside(
            thread.map { MentionWindow.Row(id: $0.id, sender: $0.senderId.string, sentAt: $0.sentAt, mentions: $0.mentions.count) },
            me: me,
            blocked: Set(blocked.map { ExactKey($0.string) }))
        rows = [:]
    }

    /// Starts a build of a thread whose stored rows are `thread`, judged under `directory`'s labels and block list, and, in
    /// a group thread, `roster`.
    mutating func begin(directory: Directory, roster: [String]?, thread: [MessageRecord]) {
        begin(labels: directory.labels, roster: roster, thread: thread, me: directory.me.string, blocked: directory.blocked)
    }

    /// Where `message`'s bubble lights the names it mentions, `me` being our node id: those of its list the thread's
    /// judge keeps (``MentionVouch``). The composer's chips read the picks unfiltered.
    mutating func spans(of message: MessageRecord, me: String) -> [Range<Int>] {
        let id = ExactKey(message.id)
        let inWindow = !outside.contains(id)
        if let row = previous[id], row.holds(message, inWindow: inWindow) {
            rows[id] = row
            return row.spans
        }
        let kept = vouch.kept(message.mentions, sender: message.senderId.string, me: me, roster: members, inWindow: inWindow)
        let spans = MentionText.spans(in: message.body, mentions: kept)
        rows[id] = Row(message, inWindow: inWindow, spans: spans)
        return spans
    }
}
