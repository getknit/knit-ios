public import KnitStore
public import KnitWire

/// The bound on strangers' photos in the Nearby room (knit-ios #21, the maintainer's decision): a room photo from someone
/// the user does not know is fetched and kept only while it is among that sender's newest ``perSender`` room photos the
/// room admits (``RoomAttachments/admits(_:)``), and, of those, among the newest ``overall`` from all strangers. Room posts
/// are metered (a burst of 240, then 30 a minute per link), but each can name a blob of up to 8 MiB + 64 KiB, so a flood of
/// strangers' posts could otherwise fill the phone. Android fetches every room photo; this bound is this port's alone, and
/// is local: what custody carries, the digest and the relay never read it.
///
/// A known sender is exempt, as in Android's `knownSenders` (`MeshManager.kt:3010` at knit-next `4408e0fca`): us, a peer
/// whose DM thread is accepted, a verified peer, or a peer we have written to. The bound applies the per-sender count
/// first, so one stranger's flood takes at most ``perSender`` of the ``overall`` slots and leaves the rest to the others.
///
/// It is a function of the rows alone. "Newest" is the stored `sentAt`, then the id by its bytes (``ExactKey``, ADR
/// 2026-09.jc2x), larger first, so the engine and the screens, which apply it to a thread's rows, agree, and so do two
/// phones holding the same rows. Arrival order is not used: a newcomer's back-fill would bring the room's oldest posts last
/// and they would push out the photos of the hour, and it is not the same on any two phones. A `sentAt` dated ahead is
/// clamped on the way in to five minutes past the clock, so a stranger who dates posts ahead outranks honest ones only by
/// those minutes.
///
/// A photo it leaves out is neither wanted nor named, so the 600 s sweep removes its bytes and nothing wants it again. It
/// must never become a budget applied by eviction alone: a blob evicted while a row still names it is wanted again at the
/// next re-offer, and that loops for good.
public enum StrangerRoomPhotos {
    /// How many of one stranger's room photos are kept, newest first: a few posts' worth, so a flood from one identity
    /// takes no more.
    public static let perSender = 8

    /// How many strangers' room photos are kept in all: 32 × (8 MiB + 64 KiB), about 256 MiB, twice the 128 MiB an asker's
    /// echoes may hold (ADR 2026-10.7kxj), for photos the user may scroll to.
    public static let overall = 32

    /// The ids, by their bytes, of the rows in `rows` whose photo the bound leaves out: a stranger's room post (in
    /// ``Conversations/nearby`` and from no sender `isKnown` takes) whose type the room does not admit, or that falls
    /// outside the newest ``perSender`` of its sender's or the newest ``overall`` of those. Any other row is never left
    /// out, so `rows` may hold rows of every thread; it must hold every room row naming a photo, or the ranking is wrong.
    public static func leftOut(_ rows: [AttachmentRow], isKnown: (NodeId) -> Bool) -> Set<ExactKey> {
        let strangers = rows.filter { $0.conversationId == Conversations.nearby && !isKnown($0.senderId) }
        var kept: [NodeId: Int] = [:]
        var keptInAll = 0
        var out: Set<ExactKey> = []
        for row in strangers.sorted(by: isNewer(_:than:)) {
            let count = kept[row.senderId, default: 0]
            guard RoomAttachments.admits(row.mime), count < perSender, keptInAll < overall else {
                out.insert(ExactKey(row.id))
                continue
            }
            kept[row.senderId] = count + 1
            keptInAll += 1
        }
        return out
    }

    /// Whether `row` is newer than `other`: a later `sentAt`, or the same and an id larger by its bytes.
    static func isNewer(_ row: AttachmentRow, than other: AttachmentRow) -> Bool {
        guard row.sentAt == other.sentAt else {
            return row.sentAt > other.sentAt
        }
        return other.id.utf8.lexicographicallyPrecedes(row.id.utf8)
    }
}
