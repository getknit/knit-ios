public import KnitWire

/// One person's reaction to one message (`ReactionEntity` in knit-next): the emoji they last chose, or `nil` once they
/// took it back, and the clock that decides which of two updates is newer.
///
/// A person holds at most one reaction per message, keyed by the message's frame id and their node id. A retraction
/// is kept as a row with no emoji, so it can still beat an older add that arrives after it. A reaction may name a
/// message this node does not hold yet; it is kept, and shows once the message lands.
public struct ReactionRecord: Sendable, Equatable {
    /// The frame id of the message reacted to, which is its ``MessageRecord/id``.
    public var messageId: String
    /// Who reacted.
    public var reactor: NodeId
    /// The emoji, or `nil` for a reaction taken back.
    public var emoji: String?
    /// The reactor's clock for this update, clamped to five minutes past ours on the way in. Last writer wins.
    public var updatedAt: Int64

    /// Makes a reaction.
    public init(messageId: String, reactor: NodeId, emoji: String?, updatedAt: Int64) {
        self.messageId = messageId
        self.reactor = reactor
        self.emoji = emoji
        self.updatedAt = updatedAt
    }
}

/// The rules for keeping reactions.
public enum Reactions {
    /// How long a reaction is kept while its message is not held (`ORPHAN_GRACE_MILLIS`, `ReactionRepository.kt`):
    /// long enough for a message to land after a reaction that overtook it, short enough to reclaim the reactions a
    /// deleted message left behind. A day, as Android keeps.
    public static let orphanGraceMilliseconds: Int64 = 86_400_000
}
