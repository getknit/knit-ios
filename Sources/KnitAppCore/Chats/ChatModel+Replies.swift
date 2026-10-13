import KnitMesh
import KnitStore
import KnitWire

// A thread's replies (ADR 2026-10.mn29), apart so `ChatModel` stays under the lint's length.
extension ChatModel {
    /// Starts a reply to `message`, from its bubble's menu, a swipe or VoiceOver: the composer holds its quote
    /// (``AppSession/quote(of:)``) until Send or Cancel reply, and its field takes focus. A status line takes none, and nor
    /// does a thread without a composer.
    public func reply(to message: ChatMessage) {
        guard message.notice == nil, state.canReply, let reply = session.quote(of: message.id) else {
            return
        }
        let quote = ChatQuote(reply, me: session.identity.nodeId, directory: session.directory, shown: [])
        replying = ComposerReply(reply: reply, quote: quote)
        repliesStarted += 1
    }

    /// Puts the held quote away, from the composer's bar.
    public func cancelReply() {
        replying = nil
    }
}
