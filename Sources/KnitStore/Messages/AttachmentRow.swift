public import KnitWire

/// One stored message naming a blob, as a fetch of that blob judges it (`AttachmentFetchRow`'s `senderId`, `sentAt` and
/// `dm`, `MessageDao.kt:346-367` at knit-next `385bfba0`): who sent it, when on the frame's clock, and whether it is a DM's,
/// which a group's and a room's rows are not. The earliest row's sender is the one holder a re-armed want can name (knit-next
/// ADR 2026-10.f7gg), and the rows' deadline bounds the pull-through (`PullThroughGate`, knit-next ADR 2026-10.2drc).
///
/// Its thread and its type are this port's (knit-ios #21): a blob is fetched and kept only for a row in a thread the user
/// accepted, and a stranger's room photo only inside the room's bound (`StrangerRoomPhotos` in KnitMesh), which counts the
/// types the room admits.
public struct AttachmentRow: Sendable, Equatable {
    /// The message's frame id.
    public var id: String
    /// Who sent it.
    public var senderId: NodeId
    /// Its stored `sentAt`, clamped on the way in as every row's is.
    public var sentAt: Int64
    /// Whether it is a DM's: it names a recipient.
    public var isDM: Bool
    /// The thread it is in (``Conversations``).
    public var conversationId: String
    /// The type its sender declared, as stored, or `nil`.
    public var mime: String?

    /// Describes message `id` from `senderId` in thread `conversationId`, sent at `sentAt`, a DM's when `isDM`, carrying a
    /// blob of type `mime`.
    public init(id: String, senderId: NodeId, sentAt: Int64, isDM: Bool, conversationId: String, mime: String? = nil) {
        self.id = id
        self.senderId = senderId
        self.sentAt = sentAt
        self.isDM = isDM
        self.conversationId = conversationId
        self.mime = mime
    }
}
