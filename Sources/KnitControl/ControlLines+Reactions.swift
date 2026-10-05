import KnitStore
import KnitWire

extension ControlLines {
    /// A reaction: the message it names, who reacted, and the emoji they hold now, `null` once taken back
    /// (ADR 2026-10.ehe6).
    static func fields(of reaction: ReactionRecord) -> [String: JSONValue] {
        ["id": .string(reaction.messageId), "from": .string(reaction.reactor.string), "emoji": .text(reaction.emoji)]
    }
}
