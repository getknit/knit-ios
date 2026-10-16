import KnitSync
public import KnitWire

/// A ``GroupRatchetStore`` in memory, for knit-peer, the tests and the demo, with `GroupRatchetDao`'s row rules as
/// knit-next's test store keeps them (`MemoryGroupRatchetStore` on the A9 branch): a send chain replaces its epoch's row,
/// a receive chain its mint's, and a skipped key is inserted only where none is stored. A spent key goes by its full key,
/// the mint included, where Kotlin's stores take every mint's key at its index (knit-next #177). Groups are keyed by
/// their ids' bytes (``ExactKey``). Its sweep is `GroupRatchetRepository`'s, which that store leaves out, through
/// ``GroupRatchetRetention``. It is ``Checkpointing``, so a ``MemoryTransactor`` over it undoes a unit's writes.
public final class MemoryGroupRatchetStore: GroupRatchetStore {
    /// A receive chain's key within a group: `(sender, epoch, mintedAt)`.
    private struct ChainId: Hashable {
        let sender: NodeId
        let epoch: Int
        let mintedAt: Int64
    }

    /// A skipped key's key within a group: `(sender, epoch, mintedAt, index)`.
    private struct SkippedId: Hashable {
        let sender: NodeId
        let epoch: Int
        let mintedAt: Int64
        let index: Int
    }

    /// Everything held for one group.
    private struct Rows {
        var sendChains: [Int: GroupSendChainRecord] = [:]
        var recvChains: [ChainId: GroupRecvChainRecord] = [:]
        var skippedKeys: [SkippedId: GroupSkippedKeyRecord] = [:]
        var outbox: [NodeId: GroupKeySendRecord] = [:]

        /// The send chains, the newest epoch first.
        var newestFirst: [GroupSendChainRecord] {
            sendChains.values.sorted { $0.epoch > $1.epoch }
        }

        /// Every send chain gone, the newest kept as a retired row; nothing, when there is none.
        mutating func retireSendChains() {
            sendChains = newestFirst.first.map { [$0.epoch: GroupRatchetRetention.retired($0)] } ?? [:]
        }

        /// A leave's or a delete's purge: the send chains retired, everything else gone.
        mutating func purge() {
            retireSendChains()
            recvChains = [:]
            skippedKeys = [:]
            outbox = [:]
        }
    }

    private let groups = Lock<[ExactKey: Rows]>([:])

    /// An empty store.
    public init() {
        // Nothing to set up.
    }

    public func sendChain(_ group: String) -> GroupSendChainRecord? {
        groups.withLock { $0[ExactKey(group)]?.newestFirst.first }
    }

    public func sendChains(_ group: String) -> [GroupSendChainRecord] {
        groups.withLock { ($0[ExactKey(group)]?.newestFirst ?? []).filter { !$0.isRetired } }
    }

    public func commitSend(_ chain: GroupSendChainRecord, in group: String) {
        groups.withLock { $0[ExactKey(group), default: Rows()].sendChains[chain.epoch] = chain }
    }

    public func retireSendChains(_ group: String) {
        groups.withLock { $0[ExactKey(group)]?.retireSendChains() }
    }

    public func recvChains(_ group: String, from sender: NodeId, epoch: Int) -> [GroupRecvChainRecord] {
        groups.withLock { groups in
            let held = groups[ExactKey(group)]?.recvChains.filter { $0.key.sender == sender && $0.key.epoch == epoch } ?? [:]
            return held.values.sorted { $0.mintedAt > $1.mintedAt }
        }
    }

    public func skippedKeys(_ group: String, from sender: NodeId, epoch: Int, index: Int) -> [GroupSkippedKeyRecord] {
        groups.withLock { groups in
            let held = groups[ExactKey(group)]?.skippedKeys.filter { id, _ in
                id.sender == sender && id.epoch == epoch && id.index == index
            }
            return (held ?? [:]).values.sorted { $0.mintedAt > $1.mintedAt }
        }
    }

    public func insertRecvChain(_ chain: GroupRecvChainRecord, in group: String, from sender: NodeId) {
        groups.withLock { groups in
            groups[ExactKey(group), default: Rows()].recvChains[ChainId(sender: sender, epoch: chain.epoch, mintedAt: chain.mintedAt)] =
                chain
        }
    }

    public func applyOpen(_ delta: GroupOpenDelta, in group: String, from sender: NodeId, se: Int, n: Int) {
        groups.withLock { groups in
            var rows = groups[ExactKey(group), default: Rows()]
            if let chain = delta.recvChain {
                rows.recvChains[ChainId(sender: sender, epoch: chain.epoch, mintedAt: chain.mintedAt)] = chain
            }
            for key in delta.skippedInserts {
                let id = SkippedId(sender: sender, epoch: key.epoch, mintedAt: key.mintedAt, index: key.index)
                if rows.skippedKeys[id] == nil {
                    rows.skippedKeys[id] = key
                }
            }
            if let mintedAt = delta.consumedSkippedMintedAt {
                rows.skippedKeys[SkippedId(sender: sender, epoch: se, mintedAt: mintedAt, index: n)] = nil
            }
            groups[ExactKey(group)] = rows
        }
    }

    public func purgeGroup(_ group: String) {
        groups.withLock { $0[ExactKey(group)]?.purge() }
    }

    public func keySend(_ group: String, member: NodeId) -> GroupKeySendRecord? {
        groups.withLock { $0[ExactKey(group)]?.outbox[member] }
    }

    public func keySends(_ group: String) -> [GroupKeySendRecord] {
        groups.withLock { $0[ExactKey(group)].map { Array($0.outbox.values) } ?? [] }.sorted { $0.member < $1.member }
    }

    public func markKeySent(_ group: String, to member: NodeId, epoch: Int, at: Int64) {
        groups.withLock { groups in
            let held = groups[ExactKey(group)]?.outbox[member]
            groups[ExactKey(group), default: Rows()].outbox[member] = GroupKeySendRecord(
                member: member,
                sentEpoch: max(epoch, held?.sentEpoch ?? 0),
                sentAt: at,
                ackedEpoch: held?.ackedEpoch ?? 0,
                ackedAt: held?.ackedAt ?? 0
            )
        }
    }

    public func markKeyAcked(_ group: String, by member: NodeId, epoch: Int, at: Int64) {
        groups.withLock { groups in
            guard var row = groups[ExactKey(group)]?.outbox[member], epoch > row.ackedEpoch else {
                return
            }
            row.ackedEpoch = epoch
            row.ackedAt = at
            groups[ExactKey(group)]?.outbox[member] = row
        }
    }

    public func deleteKeySend(_ group: String, member: NodeId) {
        groups.withLock { $0[ExactKey(group)]?.outbox[member] = nil }
    }

    public func holdings(of group: String) -> GroupRatchetHoldings {
        let rows = groups.withLock { $0[ExactKey(group)] } ?? Rows()
        var recvChains: [NodeId: [GroupRecvChainRecord]] = [:]
        for (id, chain) in rows.recvChains.sorted(by: { ($0.key.epoch, $0.key.mintedAt) < ($1.key.epoch, $1.key.mintedAt) }) {
            recvChains[id.sender, default: []].append(chain)
        }
        var skippedKeys: [NodeId: [GroupSkippedKeyRecord]] = [:]
        let byIndex = rows.skippedKeys.sorted { lhs, rhs in
            (lhs.key.epoch, lhs.key.mintedAt, lhs.key.index) < (rhs.key.epoch, rhs.key.mintedAt, rhs.key.index)
        }
        for (id, key) in byIndex {
            skippedKeys[id.sender, default: []].append(key)
        }
        return GroupRatchetHoldings(
            sendChains: rows.newestFirst,
            recvChains: recvChains,
            skippedKeys: skippedKeys,
            outbox: rows.outbox.values.sorted { $0.member < $1.member }
        )
    }

    public func sweep(now: Int64) {
        groups.withLock { groups in
            // In `GroupRatchetRepository.sweep`'s order (`GroupRatchetRepository.kt:154-160`): expired skipped keys, the
            // cap, expired receive chains, then each group's superseded send chains.
            let skippedCutoff = GroupRatchetRetention.skippedKeyCutoff(now: now)
            groups = groups.mapValues { rows in
                var kept = rows
                kept.skippedKeys = rows.skippedKeys.filter { $0.value.createdAt >= skippedCutoff }
                return kept
            }
            let stamps = groups.flatMap { group, rows in
                rows.skippedKeys.map { id, key in
                    GroupSkippedKeyStamp(
                        group: group, sender: id.sender, epoch: id.epoch, mintedAt: id.mintedAt, index: id.index, createdAt: key.createdAt)
                }
            }
            for evicted in GroupRatchetRetention.evictedSkippedKeys(stamps) {
                let id = SkippedId(sender: evicted.sender, epoch: evicted.epoch, mintedAt: evicted.mintedAt, index: evicted.index)
                groups[evicted.group]?.skippedKeys[id] = nil
            }
            let chainCutoff = GroupRatchetRetention.receiveChainCutoff(now: now)
            groups = groups.mapValues { rows in
                var kept = rows
                kept.recvChains = rows.recvChains.filter { $0.value.lastUsedAt >= chainCutoff }
                if let newest = rows.newestFirst.first {
                    let lowest = GroupRatchetRetention.lowestKeptEpoch(newest: newest.epoch, mintedAt: newest.mintedAt, now: now)
                    kept.sendChains = rows.sendChains.filter { $0.key >= lowest }
                }
                return kept
            }
        }
    }
}

extension MemoryGroupRatchetStore: Checkpointing {
    /// Every group's rows, together.
    public func checkpoint() -> StoreCheckpoint {
        let held = groups.withLock { $0 }
        return StoreCheckpoint { [self] in groups.withLock { $0 = held } }
    }
}
