import KnitStore

/// Deleting a message or a whole chat from this iPhone (ADR 2026-10.u7cq, after `ChatViewModel.deleteMessage` and
/// `ChatListViewModel.deleteConversation` in knit-next). A delete sends nothing and is read on the delivery path only.
/// Custody, the relay and receipts never see it, so our digest still agrees with every node's (ADR 2026-10.5wgg's
/// trap). Our copy of a frame stays carried until its TTL, and the deleted id is remembered for as long as any
/// carrier could re-serve the frame, so the message cannot come back. A deleted photo's bytes stay, unshown, while
/// our custody carries its frame, as Android keeps a carried frame's photo, so a node handed the frame can still fetch
/// it here.
extension MeshEngine {
    /// Deletes message `id` from its thread, and answers whether it did. A status line is never deleted on its own.
    /// One of ours already sent still reaches whoever it was for, from custody. One still waiting for a key never
    /// leaves, because nothing but its row would send it.
    @discardableResult
    public func deleteMessage(_ id: String) -> Bool {
        guard let record = stores.messages.message(id), !record.kind.isNotice else {
            return false
        }
        keepAccepted(record.conversationId)
        release([stores.messages.deleteMessage(id, at: clock.wallMilliseconds())].compactMap(\.self))
        return true
    }

    /// Deletes every row of thread `conversationId`, status lines included, and answers whether there were any. The
    /// group, its roster and our place on it stay, and nothing is sent: the group's next row brings its thread back,
    /// as on Android, and Leave group is what leaves it. The Nearby room is cleared the same way.
    @discardableResult
    public func deleteChat(_ conversationId: String) -> Bool {
        keepAccepted(conversationId)
        let removed = stores.messages.deleteMessages(in: conversationId, at: clock.wallMilliseconds())
        release(removed)
        return !removed.isEmpty
    }

    /// Accepts `conversationId` outright when it reads as accepted now, so taking its rows away never turns it into a
    /// request. A thread is accepted partly by what it holds: our own messages, the "created" line, and the people a
    /// group's ordinary messages came from (``Conversations/isAccepted(_:accepted:verified:authored:groupSenders:)``).
    /// On Android a DM accepted only because the user wrote in it becomes a request once deleted (`Conversations.kt:134`
    /// derives it the same way); here it stays accepted. The group rule leaves blocked people out, as the screens do.
    private func keepAccepted(_ conversationId: String) {
        let accepted = stores.conversations.acceptedConversations()
        guard conversationId != Conversations.nearby, !accepted.contains(conversationId) else {
            return
        }
        let groupSenders =
            Conversations.isGroup(conversationId)
            ? stores.messages.senders(in: conversationId).subtracting(stores.blocks.blockedNodeIds()) : []
        let isAccepted = Conversations.isAccepted(
            conversationId,
            accepted: accepted,
            verified: stores.peers.verifiedNodeIds(),
            authored: stores.messages.conversations(authoredBy: nodeId),
            groupSenders: groupSenders
        )
        if isAccepted {
            stores.conversations.accept(conversationId)
        }
    }

    /// Lets go of the photos `removed` carried. One no message shows stops being wanted, since nothing here pulls a
    /// carried frame's photo (ADR 2026-10.ym9y). Its bytes leave the store at once when nothing names them, a frame our
    /// custody still carries included, and otherwise once that frame goes (``releaseDeletedPhotos()``).
    private func release(_ removed: [MessageRecord]) {
        let hashes = Set(removed.compactMap(\.attachment?.hash))
        guard !hashes.isEmpty else {
            return
        }
        let shown = stores.messages.attachmentHashes()
        let named = referencedBlobs()
        for hash in hashes where !shown.contains(hash) {
            blobExchange.forget(hash)
            if !named.contains(hash) {
                stores.blobs.remove(hash)
            }
        }
        syncAcceptedFiles()
    }

    /// Removes each deleted message's photo whose frame our custody no longer carries, once nothing else names it: at
    /// every sweep, so a photo outlives its frame by at most one sweep's interval.
    func releaseDeletedPhotos() {
        let held = stores.messages.deletedAttachments().filter { !stores.custody.contains($0.id) && stores.blobs.contains($0.hash) }
        guard !held.isEmpty else {
            return
        }
        let named = referencedBlobs()
        for deleted in held where !named.contains(deleted.hash) {
            stores.blobs.remove(deleted.hash)
        }
    }
}
