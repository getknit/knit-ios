import KnitMesh
import KnitStore
import KnitWire

/// What a thread's photos show: whether each one's bytes are here, and why one the engine never fetches waits for nothing
/// (knit-ios #21, ADR 2026-10.vzem). The engine fetches nothing for a message request until it is accepted, and a
/// stranger's Nearby photo only inside the bound on strangers' photos. The thread reads the same rules, so a photo that
/// is not coming says why, where it would otherwise wait for a phone that has it.
internal struct ThreadPhotos {
    private let held: Set<BlobHash>
    private let isRequest: Bool
    private let pastBound: Set<ExactKey>

    /// The photos of `conversationId`, whose `shown` messages the thread draws, as `stores` and `threads` hold them.
    init(_ stores: MeshStores, conversationId: String, shown: [MessageRecord], threads: ThreadTable) {
        held = stores.blobs.held(among: Set(shown.compactMap(\.attachment?.hash)))
        isRequest = threads.isRequest(conversationId)
        guard ExactKey(conversationId) == ExactKey(Conversations.nearby) else {
            pastBound = []
            return
        }
        // Every room row naming a photo, a blocked sender's included, as the engine ranks them.
        let rows = stores.messages.messages(in: conversationId).compactMap { message in
            message.attachment.map { attachment in
                AttachmentRow(
                    id: message.id,
                    senderId: message.senderId,
                    sentAt: message.sentAt,
                    isDM: false,
                    conversationId: conversationId,
                    mime: attachment.mime
                )
            }
        }
        pastBound = StrangerRoomPhotos.leftOut(rows, isKnown: threads.knows)
    }

    /// Whether the blob `hash`, which a shown message names, is on this phone.
    func holds(_ hash: BlobHash) -> Bool {
        held.contains(hash)
    }

    /// `message`'s attachment as the thread shows it. A request's photo waits for accept, whatever bytes are here, since
    /// only an accept fetches it from its author. A stranger's room photo past the bound and not here says so.
    func attachment(of message: MessageRecord) -> ChatAttachment? {
        guard let stored = message.attachment, var shown = ChatAttachment(stored, isHeld: held.contains(stored.hash)) else {
            return nil
        }
        guard shown.kind == .photo else {
            return shown
        }
        if isRequest {
            shown.isHeld = false
            shown.waits = .accept
        } else if !shown.isHeld, pastBound.contains(ExactKey(message.id)) {
            shown.waits = .roomBound
        }
        return shown
    }
}
