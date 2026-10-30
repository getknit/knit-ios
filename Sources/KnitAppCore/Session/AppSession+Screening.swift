import KnitMesh
import KnitStore
import KnitWire

// Screening what the engine stored (ADR 2026-10.e4kz), apart so `AppSession` stays inside the lint's length.
extension AppSession {
    /// Screens what the engine stored and the app never got to: a launch that follows one stopped mid-screen, or events
    /// heard by nobody. In the order they were stored, before the first event is heard.
    func screenWaiting() async {
        let waiting = stores.messages.waitingForModeration()
        for message in waiting {
            _ = await screen(message)
        }
        if !waiting.isEmpty {
            revision += 1
        }
    }

    /// What the content filter makes of `message`'s words, stored on its row (`InboundPipeline.inboundModeration`), and
    /// the message as stored after. Words the filter could not read are let through, as Android lets them through: `clear`,
    /// for good.
    ///
    /// A quote is screened apart from the body, in the same scope, and only while it is unchecked: then its words are the
    /// replier's, and a flagged one hides the reply (`quoteOnArrival`, knit-next ADR 2026-10.gpa3). A verified quote takes
    /// its original's own verdict instead, which the store passes on when the original is screened, and an original that
    /// lands while this screens settles the quote over whatever this finds.
    func screen(_ message: MessageRecord) async -> MessageRecord {
        guard let stored = stores.messages.message(message.id) else {
            return message
        }
        let inRoom = message.conversationId == Conversations.nearby
        if stored.moderation == .waiting {
            let flagged = await textScreening?.isAbusive(stored.body, inRoom: inRoom) ?? false
            stores.messages.setModeration(stored.id, to: flagged ? .flagged : .clear)
        }
        if stored.quoteAwaitsScreening, let quoted = stored.replyTo?.snippet {
            let flagged = await textScreening?.isAbusive(quoted, inRoom: inRoom) ?? false
            stores.messages.setQuoteModeration(stored.id, to: flagged ? .flagged : .clear)
        }
        return stores.messages.message(message.id) ?? stored
    }
}
