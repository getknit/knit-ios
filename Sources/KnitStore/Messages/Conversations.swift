public import KnitWire

/// Which thread a message belongs to (`Conversations.kt` in knit-next): the Nearby room, or a DM keyed by the
/// other party's node id. A conversation id is plain text, so it can name either.
public enum Conversations {
    /// The Nearby room's id, `nearby`. A node id is 26 base32 characters, so it can never collide with it.
    public static let nearby = "nearby"

    /// The thread a message belongs to, from `me`'s side: the room when it has no recipient, otherwise the other
    /// party, the recipient of a message we sent or the sender of one we received.
    public static func id(sender: NodeId, recipient: NodeId?, me: NodeId) -> String {
        guard let recipient else {
            return nearby
        }
        return sender == me ? recipient.string : sender.string
    }

    /// Whether `conversationId` is accepted rather than a stranger's message request (`Conversations.isAccepted`).
    /// The room always is. A DM is when the user accepted it, verified the peer, or wrote in it. A presentation
    /// decision only: custody and relaying never read it.
    public static func isAccepted(
        _ conversationId: String,
        accepted: Set<String>,
        verified: Set<NodeId>,
        authored: Set<String>
    ) -> Bool {
        if conversationId == nearby || accepted.contains(conversationId) || authored.contains(conversationId) {
            return true
        }
        return NodeId(conversationId).map(verified.contains) ?? false
    }
}
