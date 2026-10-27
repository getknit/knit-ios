import KnitStore
import KnitWire

/// The local retention sweep (`MeshManager.sweepLocalStorage`, `MeshManager.kt:2991-3012` at knit-next `e63f15f4`), run
/// with the 600 s sweep and at start as Android runs it: the Nearby room and the message requests are trimmed by
/// ``MessageRetention`` (knit-ios #21). Like a delete it reads and writes the message rows alone (ADR 2026-10.u7cq):
/// custody, the carry gate, the digest and `PendingInbound` never read what it removed, so every node's custody stays
/// what every other node's is (ADR 2026-10.5wgg's trap).
extension MeshEngine {
    /// Trims the room and the message requests at the wall clock's now, and tells the app which threads lost rows.
    ///
    /// What to trim is read in one store unit: who the user knows, which threads are protected (``conversationsNamed(among:_:)``,
    /// blocked posters counted, so nothing a fetch or the screens take for accepted is ever trimmed), and the rows. Outside a
    /// unit a failed read of the accepted threads would make every DM a request. The rows go in a write of their own, which
    /// removes nothing when it fails; each one a carrier could still re-serve is remembered so it cannot open again as new
    /// past the router's window, which Android's bare delete lets it (``MessageStore/trimMessages(_:at:)``). Their photos'
    /// wants are let go at once, and their bytes left to the sweep of unnamed blobs (``release(_:removingUnnamed:)``).
    ///
    /// The deleted ids whose time is up are forgotten first, on the tick as at start, so a flood of trimmed requests cannot
    /// grow the tombstones between starts.
    func sweepRetention() {
        let now = clock.wallMilliseconds()
        stores.messages.pruneDeleted(before: now)
        let unit = stores.transactor.atomically { () -> [RetentionRow]? in
            let known = Acquaintances(reading: self)
            let threads = stores.messages.conversationIds()
            let protected = conversationsNamed(among: threads, known)
            let rows = stores.messages.retentionRows(in: threads.subtracting(protected).union([Conversations.nearby]))
            let room = ExactKey(Conversations.nearby)
            return MessageRetention.trims(
                room: rows.filter { ExactKey($0.conversationId) == room },
                pending: rows.filter { ExactKey($0.conversationId) != room },
                now: now,
                knows: known.knows
            )
        }
        guard case .committed(let trims) = unit else {
            log.log(.warning, "mesh retention skipped: a store failed")
            return
        }
        guard !trims.isEmpty else {
            return
        }
        let removed = stores.messages.trimMessages(trims.map(\.id), at: now)
        guard !removed.isEmpty else {
            return
        }
        release(removed, removingUnnamed: false)
        let threads = Dictionary(removed.map { (ExactKey($0.conversationId), $0.conversationId) }) { first, _ in first }
        let conversations = threads.sorted { $0.key.bytes.lexicographicallyPrecedes($1.key.bytes) }.map(\.value)
        log.log(.info, "mesh retention trimmed \(removed.count) messages from \(conversations.count) threads")
        events.append(.trimmed(conversations: conversations))
    }
}
