public import KnitWire

/// The DM ratchet's persistence (`RatchetStore` in knit-next's `mesh/crypto/ratchet/RatchetStore.kt`, over
/// `RatchetRepository` and `RatchetDao` in `data/ratchet/`, at `ac491f4c`): one session per peer, our own epoch pairs,
/// the peer's receive chains and the skipped keys, each tagged with the root that derived it (ADR 2026-10.5sk9).
///
/// Like every store here it is synchronous and never throws (ADR 2026-09.nyya): a store that fails answers as if
/// nothing were there and reports the error. The methods are transaction-agnostic, as Kotlin's are: ``applyOpen(_:from:se:n:)``
/// and ``commitSend(_:newLocalEpoch:)`` perform only their own rows, and the session layer (`RatchetSessions` in KnitMesh)
/// runs them inside a store unit (``StoreTransactor``) with everything they carry, the message row included. Inside a
/// unit any error, a read's as much as a write's, fails the unit, so no decision is taken on a fallback.
///
/// The row rules are `RatchetDao`'s (`RatchetDao.kt:18-118`): the session, a receive chain and a local epoch replace any
/// row with their key, so a local epoch minted again after our reset replaces the dead era's (knit-next ADR 027); a
/// skipped key is inserted only where none is stored; and a spent key goes by its full key, root tag included, since
/// another root's key at the same index belongs to another era's frame. Sessions are never swept.
public protocol RatchetStore: AnyObject, Sendable {
    /// The session held with `peer`, or `nil`.
    func session(_ peer: NodeId) -> RatchetSessionRecord?

    /// Every peer a session is held with, in node id order (`sessionPeerIds`, `RatchetStore.kt:20`, `RatchetDao.kt:24-25`):
    /// the whole set, which only the sealed profile's fan-out to our confirmed sessions reads (phase P5e). Kotlin's query
    /// names no order; this one does, so both stores fan out alike.
    func sessionPeerIds() -> [NodeId]

    /// Stores `session` whole, replacing any held with its peer.
    func upsertSession(_ session: RatchetSessionRecord)

    /// The private key of our epoch `epoch` for `peer`, looked up by number alone (`RatchetSessions.kt:137`), or `nil`
    /// once retired.
    func localEpochPrivateKey(_ peer: NodeId, epoch: Int) -> [UInt8]?

    /// Every receive chain held for `peer`'s `epoch`, whatever root derived it, by root tag: each root candidate reads
    /// only its own (knit-next ADR 2026-10.gcrd).
    func recvEpochs(_ peer: NodeId, epoch: Int) -> [RatchetRecvEpochRecord]

    /// Every skipped key held for `peer`'s `(epoch, index)`, whatever root derived it, by root tag.
    func skippedKeys(_ peer: NodeId, epoch: Int, index: Int) -> [RatchetSkippedKeyRecord]

    /// Persists everything an open of `peer`'s frame changed (``RatchetOpenDelta``), in its order. `se` and `n` are the
    /// frame's header's, which locate the spent skipped key (`applyOpen`, `RatchetRepository.kt:54-92`).
    func applyOpen(_ delta: RatchetOpenDelta, from peer: NodeId, se: Int, n: Int)

    /// Persists a seal: the advanced session, and the epoch pair the seal or an initiation minted, replacing any of its
    /// number (`commitSend`, `RatchetRepository.kt:94-104`).
    func commitSend(_ session: RatchetSessionRecord, newLocalEpoch: RatchetLocalEpochRecord?)

    /// Drops `peer`'s receive state, every chain and skipped key, and keeps the session and our epochs: what whoever
    /// leaves a root era does with it (`purgePeerRecvState`, `RatchetStore.kt:64-72`).
    func purgeReceiveState(_ peer: NodeId)

    /// Drops every row held for `peer`: the session, our epochs, its chains and skipped keys (`deletePeer`).
    func deletePeer(_ peer: NodeId)

    /// Everything held for `peer`, for diagnostics and the tests (``RatchetPeerRecords``).
    func records(of peer: NodeId) -> RatchetPeerRecords

    /// The retention sweep at `now`, the forward-secrecy window's enforcement point (`sweep`, `RatchetRepository.kt:121-157`):
    /// ``RatchetRetention``'s rules, which every store applies alike.
    ///
    /// On the database a deleted row is zeroed in the next write of its page (`secure_delete`), which reaches the file
    /// only at a checkpoint, and the write-ahead log keeps the frames that wrote each key until it is reset and
    /// overwritten, or truncated. The truncating checkpoint run once the sweep's outermost transaction commits does both:
    /// the file takes the zeroed pages, and the log loses each deleted key's insert and every chain key a seal or an open
    /// has replaced (ADR 2026-09.nyya, amended 2026-10-15). Between sweeps either file can hold a spent key or a replaced
    /// chain key, and a reader holding a snapshot of the log when the sweep commits puts the truncation off to the next
    /// sweep. `secure_delete` does not zero an older copy of a row that a page's rebalance left in its unused space, so
    /// rarely such a copy outlives the sweep until the space is reused. Nothing calls the sweep before P5, which runs it
    /// at start and at most hourly, as Android does.
    func sweep(now: Int64)
}
