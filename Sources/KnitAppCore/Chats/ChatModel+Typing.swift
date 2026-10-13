import KnitStore
import KnitWire

/// Typing in a thread: the cue a keystroke sends, and who the thread shows typing at its foot.
extension ChatModel {
    /// Who the thread shows typing now, of those the mesh last said were (``Typists/shown(_:me:audience:directory:)``).
    func typists(shownBy audience: ReactionAudience) -> [Typist] {
        let thread = ExactKey(conversationId)
        guard let typing = session.typing.first(where: { ExactKey($0.key) == thread })?.value else {
            return []
        }
        return Typists.shown(typing, me: session.identity.nodeId, audience: audience, directory: session.directory)
    }

    /// Tells the thread we are typing, as a keystroke does (`MessageInput`'s `onTyping` and `ChatViewModel.onUserTyping`):
    /// only while words are left in the composer, and only where it can send, not on a request, a blocked person's DM or
    /// a group nobody else is left in. The mesh lets one cue a thread through every 8 s, and the session only while Knit
    /// is in front.
    func cueTyping() {
        guard Composer.body(of: draft) != nil, state.canReply else {
            return
        }
        Task { await session.noteTyping(in: conversationId) }
    }
}
