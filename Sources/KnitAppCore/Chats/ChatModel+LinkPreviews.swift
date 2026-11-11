import KnitMesh
import KnitStore
import KnitWire

// A thread's composer and link previews (ADR 2026-11.hcvg): which thread takes a card, and the card held for Send.
extension ChatModel {
    /// The card held for Send, which the composer shows, or `nil`. A photo or a voice note held takes the one slot, and the
    /// card waits behind it until that is removed or sent.
    public var stagedCard: LinkComposer.Staged? {
        staged == nil && voice?.staged == nil ? linkComposer?.staged : nil
    }

    /// The composer's cross on the card: it goes, and its link gets no card again in this draft.
    public func removeCard() {
        linkComposer?.remove()
    }

    /// The composer this thread fetches cards with, when the build sends them: the room's card is screened on this phone
    /// first, as its words are.
    func makeLinkComposer() -> LinkComposer? {
        guard let previews = session.linkPreviews, let service = previews.service else {
            return nil
        }
        let room = ExactKey(conversationId) == ExactKey(Conversations.nearby) ? roomScreens() : nil
        return LinkComposer(previews: previews, service: service, room: room) { [weak self] in
            self?.takesCard ?? false
        }
    }

    /// Whether the thread takes a card now (`cardWanted`'s thread half): the setting is on, nothing else is held for Send,
    /// the thread can send, and everyone it goes to draws cards.
    private var takesCard: Bool {
        let thread = state
        return session.sendsLinkPreviews && staged == nil && voice?.staged == nil && thread.exists && !thread.nobodyElse
            && !thread.isBlocked && audienceDrawsCards(thread)
    }

    /// Whether everyone a message here goes to draws a card (`audienceCannotRenderCards`): the room always, and a DM or a
    /// group only when every other member's pinned profile carries `CAP_LINK_PREVIEW`, since a phone without it shows
    /// nothing for one. Silent: the words go alone otherwise.
    private func audienceDrawsCards(_ thread: ChatState) -> Bool {
        if thread.isRoom {
            return true
        }
        let me = ExactKey(session.identity.nodeId.string)
        let audience =
            thread.isGroup
            ? (session.threads().group(conversationId)?.members ?? []).filter { ExactKey($0) != me } : [conversationId]
        return !audience.isEmpty
            && audience.allSatisfy { member in
                NodeId(member).flatMap { session.stores.peers.peer($0)?.capabilities }
                    .map { Capabilities(rawValue: $0).contains(.linkPreview) } ?? false
            }
    }

    /// The screens a card bound for the room passes on this phone (ADR 2026-10.spcy): its words as the room's, and its
    /// picture as a photo about to be sent.
    private func roomScreens() -> LinkPreviewService.RoomScreens {
        let words = session.textScreening
        let pictures = screening
        return LinkPreviewService.RoomScreens(
            wordsFlagged: { await words?.isAbusive($0, inRoom: true) ?? false },
            pictureFlagged: { await pictures?.isExplicit(outgoing: $0) ?? false }
        )
    }
}
