import KnitStore
import KnitWire

extension ControlLines {
    /// A reaction: the message it names, who reacted, and the emoji they hold now, `null` once taken back
    /// (ADR 2026-10.ehe6).
    static func fields(of reaction: ReactionRecord) -> [String: JSONValue] {
        ["id": .string(reaction.messageId), "from": .string(reaction.reactor.string), "emoji": .text(reaction.emoji)]
    }

    /// The reactions standing on each message, as `{reactor: emoji}` by the message's id, the shape Android's bridge
    /// reports in `messages[].reactions` (`DebugBridgeReceiver.kt:862-880`).
    static func reactions(_ reactions: [ReactionRecord]) -> [ExactKey: JSONValue] {
        var byMessage: [ExactKey: [String: JSONValue]] = [:]
        for reaction in reactions {
            byMessage[ExactKey(reaction.messageId), default: [:]][reaction.reactor.string] = .text(reaction.emoji)
        }
        return byMessage.mapValues(JSONValue.object)
    }
}
