public import KnitWire

/// Which thread a message belongs to (`Conversations.kt` in knit-next): the Nearby room, a group keyed by its id, or a
/// DM keyed by the other party's node id. A conversation id is plain text, so it can name any of them.
public enum Conversations {
    /// The Nearby room's id, `nearby`. A node id is 26 base32 characters, so it can never collide with it.
    public static let nearby = "nearby"

    /// Whether `conversationId` names a group: it starts with `g-`, which no node id can (`kindFor`).
    public static func isGroup(_ conversationId: String) -> Bool {
        conversationId.utf8.starts(with: GroupInfo.idPrefix.utf8)
    }

    /// The thread a message belongs to, from `me`'s side (`idFor`): its group when it has one, the room when it has no
    /// recipient, otherwise the other party, the recipient of a message we sent or the sender of one we received.
    public static func id(sender: NodeId, recipient: NodeId?, group: String? = nil, me: NodeId) -> String {
        if let group {
            return group
        }
        guard let recipient else {
            return nearby
        }
        return sender == me ? recipient.string : sender.string
    }

    /// Whether `conversationId` is accepted rather than a stranger's message request (`Conversations.isAccepted`).
    /// The room always is. Any thread is when the user accepted it or wrote in it, a DM also when the user verified
    /// the peer, and a group also when one of `groupSenders`, who wrote ordinary messages in it, is someone the user
    /// accepted, verified or wrote to. Being on a group's roster is not enough. A presentation decision only: custody
    /// and relaying never read it.
    public static func isAccepted(
        _ conversationId: String,
        accepted: Set<String>,
        verified: Set<NodeId>,
        authored: Set<String>,
        groupSenders: Set<NodeId> = []
    ) -> Bool {
        if conversationId == nearby || accepted.contains(conversationId) || authored.contains(conversationId) {
            return true
        }
        if isGroup(conversationId) {
            return groupSenders.contains { accepted.contains($0.string) || verified.contains($0) || authored.contains($0.string) }
        }
        return NodeId(conversationId).map(verified.contains) ?? false
    }
}
