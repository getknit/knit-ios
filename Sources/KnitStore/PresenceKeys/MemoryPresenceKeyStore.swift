import KnitSync
public import KnitWire

/// A ``PresenceKeyStore`` in memory, for knit-peer, the tests and the demo, with the SQL store's row rules. It is
/// ``Checkpointing``, so a ``MemoryTransactor`` over it undoes a unit's writes.
public final class MemoryPresenceKeyStore: PresenceKeyStore {
    private let peers = Lock<[NodeId: [Int64: StoredPresenceKey]]>([:])

    /// An empty store.
    public init() {
        // Nothing to set up.
    }

    public func keys(of peer: NodeId) -> [StoredPresenceKey] {
        peers.withLock { $0[peer].map { $0.values.sorted { $0.held.generation > $1.held.generation } } ?? [] }
    }

    public func replaceKeys(of peer: NodeId, with rows: [HeldPresenceKey], now: Int64) {
        peers.withLock { peers in
            let before = peers[peer] ?? [:]
            var after: [Int64: StoredPresenceKey] = [:]
            for row in rows {
                let kept = before[row.generation].flatMap { $0.held == row ? $0.receivedAt : nil }
                after[row.generation] = StoredPresenceKey(held: row, receivedAt: kept ?? now)
            }
            peers[peer] = after.isEmpty ? nil : after
        }
    }

    public func peersWithKeys() -> [NodeId] {
        peers.withLock { $0.keys.sorted() }
    }

    public func deleteKeys(of peers: Set<NodeId>) {
        self.peers.withLock { held in
            for peer in peers {
                held[peer] = nil
            }
        }
    }
}

extension MemoryPresenceKeyStore: Checkpointing {
    /// Every peer's keys, together.
    public func checkpoint() -> StoreCheckpoint {
        let held = peers.withLock { $0 }
        return StoreCheckpoint { [self] in peers.withLock { $0 = held } }
    }
}
