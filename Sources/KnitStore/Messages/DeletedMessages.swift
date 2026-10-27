public import KnitWire

/// How long a deleted message's id is remembered, so the frame it came in cannot bring it back (ADR 2026-10.u7cq).
///
/// Deleting a message leaves custody alone, as on Android (`ChatViewModel.deleteMessage` in knit-next), so our own
/// copy is still carried and a carrier that missed our receipt can still re-serve its frame. Until the id is
/// forgotten, ``MessageStore/contains(_:)`` answers for it as though the row were held.
public enum DeletedMessages {
    /// When the id of a message sent at `sentAt` and deleted at `deletedAt` may be forgotten.
    ///
    /// Custody ends at `sentAt` plus the TTL by every carrier's own clock (``CustodyRules/expiry(of:now:limits:)``),
    /// and the longer TTL covers a room post as well. Counting from the delete when it is later reaches a carrier whose
    /// clock runs behind ours, for as long as the message was kept before it was deleted, and the five minutes a frame
    /// may be dated ahead are added on top.
    public static func expiry(sentAt: Int64, deletedAt: Int64, limits: CustodyLimits = CustodyLimits()) -> Int64 {
        // Wrapping, as custody's own expiry does, so a hostile `sentAt` cannot trap.
        max(sentAt, deletedAt) &+ limits.ttlMilliseconds &+ WireProtocol.maxFutureSkewMilliseconds
    }

    /// When the id of a row retention removed at `now` may be forgotten (``MessageRetention``, knit-ios #21), or `nil` when
    /// it needs no tombstone: a status line, whose id is our own, or a message sent two of its thread's TTLs and the five
    /// minutes a frame may be dated ahead before now. The TTL is custody's for its thread, six hours for a room post and a
    /// day for anything else.
    ///
    /// Two TTLs, not one: a carrier whose clock runs behind ours by up to a TTL took the frame while it was live and holds it
    /// until our `sentAt` plus the TTL plus that lag, long after our own custody let it go and our digest stopped listing it.
    /// Such a carrier may refuse the frame as dated ahead until its own clock catches up, and then hold it to our `sentAt`
    /// plus two TTLs, however soon after arrival a count trims the row. So a tombstone lasts to the later of that and one TTL
    /// past the trim, plus the skew: `max(sentAt + ttl, now) + ttl + skew`, the same window it is written in. A delete's
    /// longer tombstone over the same id keeps its own expiry. Tombstones stay bounded by about two TTLs of what arrives.
    ///
    /// Android removes the rows and remembers nothing, so a carrier that re-serves one past the router's ten minutes
    /// opens it again as new, notifies, and the next sweep removes it again. The tombstone names no photo: a delete's
    /// would keep a stranger's trimmed photo named while its frame is carried (``MessageStore/deletedAttachments()``), and
    /// out of the bytes an asker's echoes may hold (ADR 2026-10.7kxj).
    public static func trimmedExpiry(
        sentAt: Int64, kind: MessageKind, conversationId: String, at now: Int64, limits: CustodyLimits = CustodyLimits()
    ) -> Int64? {
        let isRoom = ExactKey(conversationId) == ExactKey(Conversations.nearby)
        let ttl = isRoom ? limits.roomChatTTLMilliseconds : limits.ttlMilliseconds
        let skew = WireProtocol.maxFutureSkewMilliseconds
        guard !kind.isNotice, sentAt > now &- ttl &- ttl &- skew else {
            return nil
        }
        // Wrapping, as custody's own expiry does, so a hostile `sentAt` cannot trap: past the top it lasts one TTL from the trim.
        return max(sentAt &+ ttl, now) &+ ttl &+ skew
    }
}

/// The photo a deleted message carried, by the id of the frame it came in on (ADR 2026-10.u7cq). Its bytes stay while
/// our custody carries that frame, as Android keeps a carried frame's photo (`BlobRepository.deleteIfUnreferenced`): a
/// node that is handed the frame asks for the photo, and one of ours deleted before it arrived anywhere may have no
/// other holder.
public struct DeletedAttachment: Sendable, Equatable {
    /// The deleted message's frame id.
    public var id: String
    /// The blob its photo is kept under.
    public var hash: BlobHash

    /// Names the photo `hash` that the deleted message `id` carried.
    public init(id: String, hash: BlobHash) {
        self.id = id
        self.hash = hash
    }
}
