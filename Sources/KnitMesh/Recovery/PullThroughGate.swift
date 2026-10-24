import KnitStore

/// Until when a want of ours may ask its neighbours to pull a blob through, carried on every ask as
/// `BlobRequestContent.until` (`PullThroughGate.kt` at knit-next `385bfba0`, knit-next ADR 2026-10.2drc, ADR 2026-10.8hek).
/// For a DM's attachment, a custody window from the DM's `sentAt`. A pull never needed a carrier: a phone in the middle
/// fetches by hash from whoever answers HAVE, so this deadline costs reach. Past it a DM's far end two or more hops away
/// is no longer pulled from, and is reached again once the two ends link directly. The bound is the DM's own: the mesh
/// stops carrying the frame itself a day from its `sentAt` on every node.
///
/// Folded over the rows the way Android folds them: a deadline only when every row naming the hash is a DM's, and then the
/// latest of them. A group's or a room's row means none, and one stranger's old DM naming a hash cannot cut a contact's
/// fetch short. Our own DM rows count like anyone's. A function of the rows and the frame-global clock only.
internal enum PullThroughGate {
    /// The window past a DM's `sentAt` (`ForwardRepository.DEFAULT_TTL_MS`): fixed and frame-global, the same on every
    /// node, and never the engine's configured custody limit.
    static let windowMilliseconds: Int64 = 86_400_000

    /// The deadline for pulling the attachment `rows` name through, or `nil` for none: no row, nothing to judge.
    static func until(_ rows: [AttachmentRow]) -> Int64? {
        guard !rows.isEmpty, rows.allSatisfy(\.isDM), let latest = rows.map(\.sentAt).max() else {
            return nil
        }
        // A stored `sentAt` is clamped on the way in; saturating keeps a hostile one past that from trapping.
        return latest.addingReportingOverflow(windowMilliseconds).overflow ? .max : latest + windowMilliseconds
    }

    /// The reach a want of our own re-armed from `rows`, every row naming its hash (`wantAll`'s `until`): the whole budget
    /// and the rows' deadline, re-derived. No row read means none was there or the read failed, which a SQL store cannot
    /// tell apart, so the want keeps the deadline it had: a failed read never lifts a DM's.
    static func reach(_ rows: [AttachmentRow]) -> BlobExchange.Reach {
        .own(until: until(rows), rederived: !rows.isEmpty)
    }
}
