public import KnitWire

/// The group form's persistence (`GroupRatchetStore` in knit-next's `mesh/crypto/ratchet/GroupRatchetStore.kt`, over
/// `GroupRatchetRepository` and `GroupRatchetDao` in `data/ratchet/`, at `cbf2a487`): our send chains per group, each
/// sender's receive chains and skipped keys, and the seed outbox (ADR 2026-10.5sk9).
///
/// A group is named by its id as it travels, compared by its bytes (ADR 2026-09.jc2x): a group id is wire text, so two
/// ids Swift calls equal are two groups here, as on Android. Like every store here it is synchronous and never throws
/// (ADR 2026-09.nyya): a store that fails answers as if nothing were there and reports the error. The methods are
/// transaction-agnostic, as Kotlin's are, and the session layer (`GroupRatchetSessions` in KnitMesh) runs them inside a
/// store unit (``StoreTransactor``) with everything they carry; inside a unit any error, a read's as much as a write's,
/// fails the unit, so no decision is taken on a fallback. A departure, a rejoin, a leave and a delete call
/// ``retireSendChains(_:)``, ``deleteKeySend(_:member:)`` and ``purgeGroup(_:)`` in the unit that changes the roster
/// (`GroupRepository.kt:133-134`, `:163`, `:191`, `:211`).
///
/// The row rules are `GroupRatchetDao`'s (`GroupRatchetDao.kt:16-123`): a send chain replaces its `(group, epoch)`, a
/// receive chain its `(group, sender, epoch, mintedAt)`, and a skipped key is inserted only where none is stored. A spent
/// key goes by its full key, `(group, sender, epoch, mintedAt, index)`, as the DM store spends one by its root tag: another
/// mint's key at the same index belongs to that era's frame. Kotlin's deletes every mint's key at the index
/// (`GroupRatchetDao.kt:77-84`), knit-next #177.
public protocol GroupRatchetStore: AnyObject, Sendable {
    /// Our newest send chain for `group`, by epoch, or `nil` when we never minted one or a wipe took them: the sealing
    /// epoch. It may be a retired row, which holds the number the next mint must pass; the seal is the one reader that
    /// needs it (`sendChain`, `GroupRatchetStore.kt:29-34`).
    func sendChain(_ group: String) -> GroupSendChainRecord?

    /// Our retained send chains for `group`, the newest epoch first: the current one and a draining previous one, whose
    /// seeds we re-serve. Never a retired row, which has no seed to serve (`sendChains`, `GroupRatchetRepository.kt:22-25`).
    func sendChains(_ group: String) -> [GroupSendChainRecord]

    /// Stores a mint or a seal's advance, replacing the row of its epoch (`commitSend`).
    func commitSend(_ chain: GroupSendChainRecord, in group: String)

    /// The forced rekey of a departure or a rejoin (`retireSendChains`, `GroupRatchetRepository.kt:42-46`; knit-next ADR
    /// 2026-10.xgwj): every send chain for `group` goes, the draining previous one included, and the newest epoch comes back
    /// key-less (``GroupRatchetRetention/retired(_:)``), so the next mint numbers past it. Nothing, when we never minted.
    func retireSendChains(_ group: String)

    /// `sender`'s receive chains in `group` for `epoch`, the newest mint first: the live mint and a draining older era.
    func recvChains(_ group: String, from sender: NodeId, epoch: Int) -> [GroupRecvChainRecord]

    /// `sender`'s stored keys in `group` for exactly `(epoch, index)`, any mint's, the newest mint first.
    func skippedKeys(_ group: String, from sender: NodeId, epoch: Int, index: Int) -> [GroupSkippedKeyRecord]

    /// Stores a freshly adopted receive chain of `sender`'s; older mints of its epoch stay, and drain through the sweep.
    func insertRecvChain(_ chain: GroupRecvChainRecord, in group: String, from sender: NodeId)

    /// Persists everything an open of `sender`'s frame changed (``GroupOpenDelta``), in its order. `se` and `n` are the
    /// frame's header's, and with the delta's mint they name the one stored key spent (`applyOpen`,
    /// `GroupRatchetStore.kt:74-86`). Kotlin's delta names the index alone and its store takes every mint's key there,
    /// which its doc prices as a benign `AEAD_FAIL` and a key request: in fact the other era's frame at that index then
    /// drops as `DUPLICATE` at every re-serve, and no key request could bring its key back (knit-next #177).
    func applyOpen(_ delta: GroupOpenDelta, in group: String, from sender: NodeId, se: Int, n: Int)

    /// Drops `group`'s receive chains, skipped keys and outbox on a leave or a delete, and retires its send chains rather
    /// than deleting them: the same people put together again are the same group, and the next mint must number past
    /// what the others hold (`purgeGroup`, `GroupRatchetRepository.kt:100-108`; knit-next ADR 2026-10.xgwj).
    func purgeGroup(_ group: String)

    /// `member`'s outbox row in `group`, or `nil` when we never sent it a seed.
    func keySend(_ group: String, member: NodeId) -> GroupKeySendRecord?

    /// Every outbox row in `group`, in member order.
    func keySends(_ group: String) -> [GroupKeySendRecord]

    /// Records that we sent `member` our `epoch` at `at`: the row's sent epoch only rises, and any recorded ack is kept
    /// (`markKeySent`, `GroupRatchetRepository.kt:117-134`).
    func markKeySent(_ group: String, to member: NodeId, epoch: Int, at: Int64)

    /// Records `member`'s acknowledgement of `epoch` at `at`: only a newer epoch than the one recorded moves the row, and
    /// an acknowledgement with no row is ignored (`markKeyAcked`, `GroupRatchetRepository.kt:136-145`).
    func markKeyAcked(_ group: String, by member: NodeId, epoch: Int, at: Int64)

    /// Drops `member`'s outbox row in `group`: its departure, which ends it as a distribution target.
    func deleteKeySend(_ group: String, member: NodeId)

    /// Everything held for `group`, for diagnostics and the tests (``GroupRatchetHoldings``).
    func holdings(of group: String) -> GroupRatchetHoldings

    /// The retention sweep at `now`, the group form's forward-secrecy enforcement point (`sweep`,
    /// `GroupRatchetRepository.kt:154-181`): ``GroupRatchetRetention``'s rules, which every store applies alike.
    ///
    /// On the database a deleted row is zeroed in the next write of its page (`secure_delete`), and the truncating
    /// checkpoint run once the sweep's outermost transaction commits copies those pages over the file and empties the
    /// write-ahead log, which held each deleted key's insert and every chain key a seal or an open replaced (ADR
    /// 2026-09.nyya, amended 2026-10-15), unless a reader holds a snapshot of the log then. Between sweeps either file can
    /// hold such a key, as the DM ratchet's can.
    func sweep(now: Int64)
}
