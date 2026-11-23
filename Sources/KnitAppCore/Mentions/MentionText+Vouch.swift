public import KnitStore
public import KnitWire

extension MentionText {
    /// The entries of a received row's `mentions` this phone lights (`vouchedMentions` in knit-next's `MentionText.kt`,
    /// knit-ios #36): ``spans(in:mentions:)`` then runs over these alone. ``MentionVouch`` says how each is judged; a
    /// thread judging many rows keeps one, so what it works out for an id serves every row.
    public static func vouched(
        _ mentions: [MessageMention], sender: String, me: String, roster: [String]?, labels: PeerLabelIndex, inWindow: Bool = true
    ) -> [MessageMention] {
        var vouch = MentionVouch(labels: labels)
        return vouch.kept(mentions, sender: sender, me: me, roster: roster, inWindow: inWindow)
    }
}

/// The judge of which received mentions a bubble lights, over one label index (knit-ios #36). The list itself, what
/// "mentions me" reads and the notification, stays as it came. Each entry is settled by the first step that applies:
///
/// 1. Our own message, `sender` being `me`, keeps every entry: our composer wrote the names.
/// 2. An entry named exactly `everyone` (``MentionCandidate/everyoneName``) in a group thread, `roster` being its current
///    members, is kept when its node id is a member's or ours, and dropped otherwise, even under a label that reads
///    "everyone" (ADR 2026-10.jwst). In any other thread, `roster` being `nil`, it goes on to the name rule.
/// 3. Any other entry is judged by its name, within three bounds that keep a long list or a long thread from making a
///    thread slow to draw (the paired contract's revisions 2 and 3). In a row outside its thread's window
///    (``MentionWindow``), every such entry drops. A name longer than ``maxNameUnits`` drops. Of the entries left, only
///    those whose node id is among the first ``maxJudgedIds`` distinct ids to reach this step, in list order, are judged,
///    and the rest drop; entries the steps above settled never count. A judged entry is kept when its name has the
///    ``NameKey`` of one of ``PeerLabelIndex/mentionTexts(for:)``: the label the index gives its node id, or that label
///    grown by more of the id's own alias tokens.
///
/// A genuine mention draws plain where this phone's label for the person differs from the sender's: a rename, a clash
/// only this phone sees, a name the content filter hides here. Android's MeshCore room, its step 2, keeps every entry;
/// this port has no such room. Node ids compare by their bytes, as Kotlin's `==` compares them, and names by their keys'
/// bytes.
public struct MentionVouch: Sendable {
    /// The longest name the name rule reads, in UTF-16 code units. A stock sender's longest label is 344: a 32-unit name
    /// and ten alias tokens of up to 30 characters.
    public static let maxNameUnits = 512
    /// How many distinct node ids one row's name rule judges. A group holds at most eight people, and the room's
    /// composer picks people one at a time.
    public static let maxJudgedIds = 16

    /// The labels each name is judged against.
    public private(set) var labels: PeerLabelIndex
    /// The keys of each id's accepted texts, worked out once for ``labels``.
    private var accepted: [ExactKey: Set<ExactKey>] = [:]
    /// Each name's key, worked out once: it owes nothing to the labels.
    private var keys: [ExactKey: ExactKey] = [:]

    /// A judge over `labels`.
    public init(labels: PeerLabelIndex) {
        self.labels = labels
    }

    /// Judges under `labels` from now on, forgetting what it worked out under the old ones but keeping each name's key.
    public mutating func relabel(_ labels: PeerLabelIndex) {
        self.labels = labels
        accepted = [:]
    }

    /// Forgets every id and name but `ids` and `names`, so the memos hold what a thread's rows name and no more.
    public mutating func retain(ids: Set<ExactKey>, names: Set<ExactKey>) {
        accepted = accepted.filter { ids.contains($0.key) }
        keys = keys.filter { names.contains($0.key) }
    }

    /// The entries of `mentions` a row from `sender` keeps, in a group with `roster` or, with none, any other thread, the
    /// row being inside its thread's window or not.
    public mutating func kept(
        _ mentions: [MessageMention], sender: String, me: String, roster: [String]?, inWindow: Bool = true
    ) -> [MessageMention] {
        guard !mentions.isEmpty, ExactKey(sender) != ExactKey(me) else {
            return mentions
        }
        let ours = ExactKey(me)
        let members = roster.map { Set($0.map(ExactKey.init)) }
        let everyone = ExactKey(MentionCandidate.everyoneName)
        var judged: Set<ExactKey> = []
        return mentions.filter { mention in
            let id = ExactKey(mention.nodeId)
            let name = ExactKey(mention.name)
            if let members, name == everyone {
                return members.contains(id) || id == ours
            }
            guard inWindow, mention.name.utf16.count <= Self.maxNameUnits, judged.contains(id) || judged.count < Self.maxJudgedIds
            else {
                return false
            }
            judged.insert(id)
            return accepts(id, mention.nodeId).contains(key(name, mention.name))
        }
    }

    private mutating func accepts(_ id: ExactKey, _ nodeId: String) -> Set<ExactKey> {
        if let known = accepted[id] {
            return known
        }
        let texts = Set(labels.mentionTexts(for: nodeId).map { ExactKey(NameKey.quick($0)) })
        accepted[id] = texts
        return texts
    }

    private mutating func key(_ name: ExactKey, _ text: String) -> ExactKey {
        if let known = keys[name] {
            return known
        }
        let key = ExactKey(NameKey.quick(text))
        keys[name] = key
        return key
    }
}
