public import KnitStore
import KnitWire

/// Reactions (ADR 2026-10.ehe6, after `MeshManager.sendReaction` and `InboundPipeline.handleReaction` in knit-next).
///
/// This build never advertises `CAP_RATCHET`, so no Android phone seals a reaction toward it, and it seals none:
/// every reaction is a signed, cleartext `reaction` frame naming no recipient and no group, flooded and carried like
/// any custodial frame for 24 hours. A reaction is applied last writer wins per message and reactor, never acknowledged
/// and never notified. Like a delete or a block, nothing here is read by custody: the carry above the handler has
/// already run, so every node's digest agrees whatever this one shows.
extension MeshEngine {
    /// Reacts to message `messageId` with `emoji`, or takes our reaction back when `emoji` is the one we hold, and
    /// answers what we now hold: a reaction whose ``ReactionRecord/emoji`` is `nil` once taken back, or `nil` when
    /// nothing changed. Only a held ordinary message takes one, and only an emoji this build accepts
    /// (``TextLimits/isAcceptedReaction(_:)``). Applied here first, then flooded (`MeshManager.sendReaction`).
    @discardableResult
    public func react(to messageId: String, with emoji: String) -> ReactionRecord? {
        guard TextLimits.isAcceptedReaction(emoji), let message = stores.messages.message(messageId), message.kind == .message
        else {
            return nil
        }
        let held = stores.messages.reaction(on: messageId, by: nodeId)
        // Compared by their bytes, as Kotlin compares them: Swift's equality would call two spellings of one emoji the
        // same, and send a retraction where Android sends a replacement (ADR 2026-09.jc2x).
        let next = held?.emoji.map(ExactKey.init) == ExactKey(emoji) ? nil : emoji
        let reaction = ReactionRecord(messageId: messageId, reactor: nodeId, emoji: next, updatedAt: stamp(after: held))
        guard stores.messages.applyReaction(reaction) else {
            return nil
        }
        // One clock for the row and the frame, so our own frame coming back ties and changes nothing.
        originate(
            RelayEnvelope(
                type: .reaction,
                id: newFrameId(),
                senderId: nodeId.string,
                sentAt: reaction.updatedAt,
                payload: ReactionContent(messageId: messageId, emoji: next).encoded
            )
        )
        return reaction
    }

    /// Someone's reaction (`InboundPipeline.handleReaction`): a blocked sender's is dropped, one that is not a single
    /// short emoji is refused, and the rest apply if strictly newer than what is held. Only a change to a message we
    /// hold is announced: most reactions a relay sees name someone else's DM, and would otherwise rebuild every screen.
    func handleReaction(_ envelope: RelayEnvelope) {
        guard let sender = NodeId(envelope.senderId) else {
            return
        }
        if isBlocked(sender) {
            // Never `dropBlocked`: it ticks a frame that names no recipient as a room post, and a reaction earns no tick.
            drop(.blocked, envelope)
            return
        }
        guard let content = try? ReactionContent(decoding: envelope.payload) else {
            drop(.undecodable, envelope)
            return
        }
        if let emoji = content.emoji, !TextLimits.isAcceptedReaction(emoji) {
            drop(.reactionRefused, envelope)
            return
        }
        let reaction = ReactionRecord(
            messageId: content.messageId,
            reactor: sender,
            emoji: content.emoji,
            updatedAt: clampFuture(envelope.sentAt)
        )
        guard stores.messages.applyReaction(reaction), stores.messages.message(content.messageId)?.kind == .message else {
            return
        }
        events.append(.reacted(reaction))
    }

    /// Forgets the reactions kept for a day with no message to show them on (`ReactionRepository.deleteOrphans`).
    /// Android does this once at start; here every sweep does, because a relay keeps every reaction it sees to
    /// someone else's DM, and knit-peer may run for weeks without a restart.
    func pruneOrphanReactions() {
        stores.messages.pruneOrphanReactions(updatedBefore: clock.wallMilliseconds() &- Reactions.orphanGraceMilliseconds)
    }

    /// The clock for a reaction of ours after `held`: now, or one past what is held when two taps fall in the same
    /// millisecond, so the second still wins here as it does everywhere it arrives; never past the five minutes ahead
    /// every receiver clamps to.
    private func stamp(after held: ReactionRecord?) -> Int64 {
        let now = clock.wallMilliseconds()
        let next = held.map { max(now, $0.updatedAt &+ 1) } ?? now
        return min(next, now &+ WireProtocol.maxFutureSkewMilliseconds)
    }
}
