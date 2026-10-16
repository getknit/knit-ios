import KnitSync
public import KnitWire

/// A ``RatchetStore`` in memory, for knit-peer, the tests and the demo, with `RatchetDao`'s row rules as knit-next's
/// test store keeps them (`MemoryRatchetStore`, `RatchetTranscript.kt:136-232`): the session, a receive chain and a local
/// epoch replace any row with their key, a skipped key is inserted only where none is stored, and a spent key goes by its
/// own root's tag. Its sweep is `RatchetRepository`'s, which that store leaves out, through ``RatchetRetention``. It is
/// ``Checkpointing``, so a ``MemoryTransactor`` over it undoes a unit's writes.
public final class MemoryRatchetStore: RatchetStore {
    /// A receive chain's key for one peer: `(epoch, rootTag)`.
    private struct ChainKey: Hashable {
        let epoch: Int
        let rootTag: Int64
    }

    /// A skipped key's key for one peer: `(epoch, index, rootTag)`.
    private struct SkippedKeyId: Hashable {
        let epoch: Int
        let index: Int
        let rootTag: Int64
    }

    /// Everything held for one peer.
    private struct Rows {
        var session: RatchetSessionRecord?
        var localEpochs: [Int: RatchetLocalEpochRecord] = [:]
        var recvEpochs: [ChainKey: RatchetRecvEpochRecord] = [:]
        var skippedKeys: [SkippedKeyId: RatchetSkippedKeyRecord] = [:]

        mutating func purgeReceiveState() {
            recvEpochs = [:]
            skippedKeys = [:]
        }
    }

    private let peers = Lock<[NodeId: Rows]>([:])

    /// An empty store.
    public init() {
        // Nothing to set up.
    }

    public func session(_ peer: NodeId) -> RatchetSessionRecord? {
        peers.withLock { $0[peer]?.session }
    }

    public func sessionPeerIds() -> [NodeId] {
        peers.withLock { peers in peers.filter { $0.value.session != nil }.keys.sorted() }
    }

    public func upsertSession(_ session: RatchetSessionRecord) {
        peers.withLock { $0[session.peerId, default: Rows()].session = session }
    }

    public func localEpochPrivateKey(_ peer: NodeId, epoch: Int) -> [UInt8]? {
        peers.withLock { $0[peer]?.localEpochs[epoch]?.privateKey }
    }

    public func recvEpochs(_ peer: NodeId, epoch: Int) -> [RatchetRecvEpochRecord] {
        peers.withLock { peers in
            (peers[peer]?.recvEpochs.values.filter { $0.epoch == epoch } ?? []).sorted { $0.rootTag < $1.rootTag }
        }
    }

    public func skippedKeys(_ peer: NodeId, epoch: Int, index: Int) -> [RatchetSkippedKeyRecord] {
        peers.withLock { peers in
            (peers[peer]?.skippedKeys.values.filter { $0.epoch == epoch && $0.index == index } ?? []).sorted { $0.rootTag < $1.rootTag }
        }
    }

    public func applyOpen(_ delta: RatchetOpenDelta, from peer: NodeId, se: Int, n: Int) {
        peers.withLock { peers in
            var rows = peers[peer, default: Rows()]
            if delta.purgePeerRecvState {
                rows.purgeReceiveState()
            }
            rows.session = delta.session
            if let chain = delta.recvEpoch {
                rows.recvEpochs[ChainKey(epoch: chain.epoch, rootTag: chain.rootTag)] = chain
            }
            for key in delta.skippedInserts {
                let id = SkippedKeyId(epoch: key.epoch, index: key.index, rootTag: key.rootTag)
                if rows.skippedKeys[id] == nil {
                    rows.skippedKeys[id] = key
                }
            }
            if let tag = delta.consumedSkippedTag {
                rows.skippedKeys[SkippedKeyId(epoch: se, index: n, rootTag: tag)] = nil
            }
            peers[peer] = rows
        }
    }

    public func commitSend(_ session: RatchetSessionRecord, newLocalEpoch: RatchetLocalEpochRecord?) {
        peers.withLock { peers in
            var rows = peers[session.peerId, default: Rows()]
            rows.session = session
            if let newLocalEpoch {
                rows.localEpochs[newLocalEpoch.epoch] = newLocalEpoch
            }
            peers[session.peerId] = rows
        }
    }

    public func purgeReceiveState(_ peer: NodeId) {
        peers.withLock { $0[peer]?.purgeReceiveState() }
    }

    public func deletePeer(_ peer: NodeId) {
        peers.withLock { $0[peer] = nil }
    }

    public func records(of peer: NodeId) -> RatchetPeerRecords {
        let rows = peers.withLock { $0[peer] } ?? Rows()
        return RatchetPeerRecords(
            session: rows.session,
            localEpochs: rows.localEpochs.values.sorted { ($0.createdAt, $0.epoch) > ($1.createdAt, $1.epoch) },
            recvEpochs: rows.recvEpochs.values.sorted { ($0.epoch, $0.rootTag) < ($1.epoch, $1.rootTag) },
            skippedKeys: rows.skippedKeys.values.sorted { ($0.epoch, $0.rootTag, $0.index) < ($1.epoch, $1.rootTag, $1.index) }
        )
    }

    public func sweep(now: Int64) {
        peers.withLock { peers in
            // In `RatchetRepository.sweep`'s order (`RatchetRepository.kt:121-127`): expired skipped keys, the cap, expired
            // receive chains, then our epochs for every peer we hold a session with.
            let skippedCutoff = RatchetRetention.skippedKeyCutoff(now: now)
            peers = peers.mapValues { rows in
                var kept = rows
                kept.skippedKeys = rows.skippedKeys.filter { $0.value.createdAt >= skippedCutoff }
                return kept
            }
            let stamps = peers.flatMap { peer, rows in
                rows.skippedKeys.values.map { key in
                    RatchetSkippedKeyStamp(peer: peer, epoch: key.epoch, index: key.index, rootTag: key.rootTag, createdAt: key.createdAt)
                }
            }
            for evicted in RatchetRetention.evictedSkippedKeys(stamps) {
                peers[evicted.peer]?.skippedKeys[SkippedKeyId(epoch: evicted.epoch, index: evicted.index, rootTag: evicted.rootTag)] = nil
            }
            let chainCutoff = RatchetRetention.receiveChainCutoff(now: now)
            peers = peers.mapValues { rows in
                var kept = rows
                kept.recvEpochs = rows.recvEpochs.filter { $0.value.lastUsedAt >= chainCutoff }
                // Only a peer we hold a session with, whose `highestPeAcked` says what it has moved past.
                if let session = rows.session {
                    let held = rows.localEpochs.values.map { (epoch: $0.epoch, createdAt: $0.createdAt) }
                    for epoch in RatchetRetention.retiredLocalEpochs(held, highestPeAcked: session.highestPeAcked, now: now) {
                        kept.localEpochs[epoch] = nil
                    }
                }
                return kept
            }
        }
    }
}

extension MemoryRatchetStore: Checkpointing {
    /// Every peer's rows, together.
    public func checkpoint() -> StoreCheckpoint {
        let held = peers.withLock { $0 }
        return StoreCheckpoint { [self] in peers.withLock { $0 = held } }
    }
}
