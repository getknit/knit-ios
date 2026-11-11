import KnitSync
public import KnitWire

/// A ``PresenceKeyStore`` in memory, for knit-peer, the tests and the demo, with the SQL store's row rules. It is
/// ``Checkpointing``, so a ``MemoryTransactor`` over it undoes a unit's writes. Its mark writes answer what the SQL
/// store's would: refused when the key is gone or no longer the current one, and, when made with `durableMarks` off, as
/// a commit that would not have run at `synchronous=FULL`, which only a test asks for.
public final class MemoryPresenceKeyStore: PresenceKeyStore {
    private struct Held {
        var peers: [NodeId: [Int64: StoredPresenceKey]] = [:]
        var own: [Int64: OwnPresenceKeyRecord] = [:]
    }

    private let held = Lock(Held())
    private let durableMarks: Bool
    /// The unit this store commits in, once told (``commits(in:)``), held weakly: the transactor holds the store.
    private let transactor = Lock<WeakTransactor>(WeakTransactor())

    /// An empty store, whose mark writes are durable unless `durableMarks` is off.
    public init(durableMarks: Bool = true) {
        self.durableMarks = durableMarks
    }

    public func keys(of peer: NodeId) -> [StoredPresenceKey] {
        held.withLock { $0.peers[peer].map { $0.values.sorted { $0.held.generation > $1.held.generation } } ?? [] }
    }

    public func replaceKeys(of peer: NodeId, with rows: [HeldPresenceKey], now: Int64) {
        held.withLock { held in
            let before = held.peers[peer] ?? [:]
            var after: [Int64: StoredPresenceKey] = [:]
            for row in rows {
                let kept = before[row.generation].flatMap { $0.held == row ? $0.receivedAt : nil }
                after[row.generation] = StoredPresenceKey(held: row, receivedAt: kept ?? now)
            }
            held.peers[peer] = after.isEmpty ? nil : after
        }
    }

    public func peersWithKeys() -> [NodeId] {
        held.withLock { $0.peers.keys.sorted() }
    }

    public func deleteKeys(of peers: Set<NodeId>) {
        held.withLock { held in
            for peer in peers {
                held.peers[peer] = nil
            }
        }
    }

    public func ownKeys() -> [OwnPresenceKeyRecord] {
        held.withLock { $0.own.values.sorted { $0.generation > $1.generation } }
    }

    public func applyOwn(inserted: [OwnPresenceKeyRecord], updated: [OwnPresenceKeyRecord], keep: Set<Int64>) {
        held.withLock { held in
            for row in updated {
                guard var stored = held.own[row.generation] else {
                    continue
                }
                // The activation and the audience alone: the mark stays as the advertiser last wrote it.
                stored.activatedAt = row.activatedAt
                stored.audience = row.audience
                held.own[row.generation] = stored
            }
            for row in inserted {
                held.own[row.generation] = OwnPresenceKeyRecord(
                    generation: row.generation, key: row.key, mintedAt: row.mintedAt, activatedAt: row.activatedAt, audience: row.audience)
            }
            held.own = held.own.filter { keep.contains($0.key) }
        }
    }

    public func mark(of generation: Int64) -> PresenceMark? {
        held.withLock { $0.own[generation]?.mark }
    }

    /// Names `unit` as the one this store commits in, so a mark asked inside it is refused at once, as the SQL store refuses
    /// one (``PresenceMarkWrite/insideUnit``).
    public func commits(in unit: MemoryTransactor) {
        transactor.withLock { $0.unit = unit }
    }

    public func writeMark(_ mark: PresenceMark, of generation: Int64) -> PresenceMarkWrite {
        if transactor.withLock({ $0.unit })?.unitRunsOnThisThread == true {
            return .insideUnit
        }
        guard durableMarks else {
            return .notFull
        }
        return held.withLock { held in
            let current = held.own.values.filter { $0.activatedAt != nil }.map(\.generation).max()
            guard let row = held.own[generation], current == generation, PresenceMark.moves(row.mark, to: mark) else {
                return .refused
            }
            held.own[generation] = OwnPresenceKeyRecord(
                generation: row.generation,
                key: row.key,
                mintedAt: row.mintedAt,
                activatedAt: row.activatedAt,
                audience: row.audience,
                mark: mark
            )
            return .durable
        }
    }
}

extension MemoryPresenceKeyStore: Checkpointing {
    /// Every peer's keys and our own, together.
    public func checkpoint() -> StoreCheckpoint {
        let saved = held.withLock { $0 }
        return StoreCheckpoint { [self] in held.withLock { $0 = saved } }
    }
}

/// A transactor held weakly.
private struct WeakTransactor {
    weak var unit: MemoryTransactor?
}
