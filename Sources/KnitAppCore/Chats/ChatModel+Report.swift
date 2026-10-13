import KnitMesh
import KnitStore

// A thread's reports (ADR 2026-10.f6kf), apart so `ChatModel` stays under the lint's length.
extension ChatModel {
    /// A report of `message`, from its bubble's menu (ADR 2026-10.f6kf), or `nil` for one of ours or a status line. It
    /// names the author as the thread does, and keeps the words whatever the content filter hid, a reply's quote's
    /// included (ADR 2026-10.mn29).
    public func reporting(_ message: ChatMessage) -> AbuseReport? {
        guard !message.isMine, message.notice == nil else {
            return nil
        }
        let thread = state
        let place: AbuseReport.Place =
            switch thread.kind {
            case .room:
                .room
            case .group:
                .group(thread.title)
            case .direct:
                thread.isRequest ? .request : .direct
            }
        return AbuseReport(
            person: message.author,
            name: message.authorLabel ?? thread.title,
            place: place,
            messageId: message.id,
            words: message.body,
            sentAt: message.sentAt,
            hadPhoto: message.attachment?.kind == .photo,
            quote: message.quote.map { quote in
                let carried = session.stores.messages.message(message.id)?.replyTo?.snippet ?? ""
                return AbuseReport.Quote(author: quote.author, words: carried.isEmpty ? quote.line ?? "" : carried)
            }
        )
    }
}
