import KnitMesh
import KnitStore
import KnitWire

// A thread's replies (ADR 2026-10.mn29), apart so `ChatModel` stays under the lint's length.
extension ChatModel {
    /// Starts a reply to `message`, from its bubble's menu, a swipe or VoiceOver: the composer holds its quote until Send
    /// or Cancel reply, and its field takes focus. A status line takes none, and nor does a thread without a composer.
    ///
    /// The quote is what Android's composer writes (`ChatScreen.kt:1352-1388`): the author's own name, ours included,
    /// never "You"; words the filter hides from us left out; a label for a GIF, a file or a voice note with no words.
    public func reply(to message: ChatMessage) {
        guard message.notice == nil, state.canReply, let record = session.stores.messages.message(message.id) else {
            return
        }
        let me = session.identity.nodeId
        let directory = session.directory
        let reply = MessageReply.quoting(
            record,
            authorName: directory.label(for: record.senderId).name,
            hidesWords: record.hidesWords(filtering: session.filtersContent, me: me),
            attachmentLabel: TextLimits.isBlank(record.body) ? AttachmentKind.quoteLabel(of: record.attachment) : nil
        )
        replying = ComposerReply(reply: reply, quote: ChatQuote(reply, me: me, directory: directory, shown: []))
        repliesStarted += 1
    }

    /// Puts the held quote away, from the composer's bar.
    public func cancelReply() {
        replying = nil
    }
}
