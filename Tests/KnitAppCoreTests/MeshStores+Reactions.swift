import KnitMesh
import KnitStore
import KnitWire

extension MeshStores {
    /// What the engine does to the stores for a reaction of ours (`MeshEngine+Reactions.swift`, ADR 2026-10.ehe6): only an
    /// accepted emoji on a held ordinary message, and the emoji we hold again takes it back.
    func react(to messageId: String, with emoji: String, at now: Int64, me: NodeId) -> ReactionRecord? {
        guard TextLimits.isAcceptedReaction(emoji), messages.message(messageId)?.kind == .message else {
            return nil
        }
        let held = messages.reaction(on: messageId, by: me)
        let next = held?.emoji.map(ExactKey.init) == ExactKey(emoji) ? nil : emoji
        let reaction = ReactionRecord(messageId: messageId, reactor: me, emoji: next, updatedAt: max(now, (held?.updatedAt ?? now) + 1))
        return messages.applyReaction(reaction) ? reaction : nil
    }
}
