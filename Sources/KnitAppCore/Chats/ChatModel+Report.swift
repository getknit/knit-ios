import KnitMesh
import KnitStore

// A thread's reports (ADR 2026-10.f6kf), apart so `ChatModel` stays under the lint's length.
extension ChatModel {
    /// A report of `message`, from its bubble's menu (ADR 2026-10.f6kf), or `nil` for one of ours or a status line. It
    /// names the author as the thread does, and keeps the words whatever the content filter hid, a reply's quote's
    /// included (ADR 2026-10.mn29), and so the author's name and the group's (knit-next ADR 2026-11.y4pc).
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
                .group(
                    session.threads().group(conversationId).map { group in
                        GroupNaming.reportedTitle(of: group, me: session.identity.nodeId, directory: session.directory)
                    } ?? thread.title)
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
            // An unavailable quote kept nothing of its claim, so a report has nothing of it to name (knit-next ADR
            // 2026-10.gpa3).
            quote: message.quote.flatMap { quote in
                guard quote.state != .unavailable else {
                    return nil
                }
                let carried = session.stores.messages.message(message.id)?.replyTo?.snippet ?? ""
                return AbuseReport.Quote(author: quote.author, words: carried.isEmpty ? quote.line ?? "" : carried)
            },
            hiddenName: session.directory.hiddenName(of: message.author)
        )
    }
}
