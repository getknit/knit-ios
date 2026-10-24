public import KnitWire

/// One stored message naming a blob, as a fetch of that blob judges it (`AttachmentFetchRow`'s `senderId`, `sentAt` and
/// `dm`, `MessageDao.kt:346-367` at knit-next `385bfba0`): who sent it, when on the frame's clock, and whether it is a DM's,
/// which a group's and a room's rows are not. The earliest row's sender is the one holder a re-armed want can name (knit-next
/// ADR 2026-10.f7gg), and the rows' deadline bounds the pull-through (`PullThroughGate`, knit-next ADR 2026-10.2drc).
public struct AttachmentRow: Sendable, Equatable {
    /// The message's frame id.
    public var id: String
    /// Who sent it.
    public var senderId: NodeId
    /// Its stored `sentAt`, clamped on the way in as every row's is.
    public var sentAt: Int64
    /// Whether it is a DM's: it names a recipient.
    public var isDM: Bool

    /// Describes message `id` from `senderId`, sent at `sentAt`, a DM's when `isDM`.
    public init(id: String, senderId: NodeId, sentAt: Int64, isDM: Bool) {
        self.id = id
        self.senderId = senderId
        self.sentAt = sentAt
        self.isDM = isDM
    }
}
