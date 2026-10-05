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
