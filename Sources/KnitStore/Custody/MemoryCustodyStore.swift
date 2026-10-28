import KnitSync
import KnitWire

/// A ``CustodyStore`` in memory, for the Linux peer and the tests. It applies ``CustodyRules`` exactly as the SQL
/// store will, keys frames by their ids' bytes (``ExactKey``), and is safe to share across threads.
public final class MemoryCustodyStore: CustodyStore {
    private struct Row: Sendable {
        var frame: CarriedFrame
        var entry: CustodyRules.Entry
        var origin: CustodyOrigin
        var receivedAt: Int64
        /// Insertion order, which breaks ties in `receivedAt`.
        var sequence: Int
    }

    private struct State: Sendable {
        var limits: CustodyLimits
        var rows: [ExactKey: Row] = [:]
        var nextSequence = 0

        func live(now: Int64) -> [Row] {
            rows.values.filter { $0.entry.expiresAt >= now }
        }
    }

    private let state: Lock<State>

    /// An empty store with knit-next's limits unless told otherwise.
    public init(limits: CustodyLimits = CustodyLimits()) {
        state = Lock(State(limits: limits))
    }

    /// The limits every rule here runs under. Settable only by a test, which stands for the SQL store reopened by a newer
    /// build: rows stored under looser limits, then swept under the current ones, as an upgrade meets a row a build without
    /// the byte cap kept (knit-next #227).
    var limits: CustodyLimits {
        get { state.withLock { $0.limits } }
        set { state.withLock { $0.limits = newValue } }
    }

    /// Which frames came from where, for a test or a diagnostic.
    public func origin(of id: String) -> CustodyOrigin? {
        state.withLock { $0.rows[ExactKey(id)]?.origin }
    }

    /// Every id held, expired rows included, sorted: what a diagnostic dump shows.
    public func allIds() -> [String] {
        state.withLock { $0.rows.values.map(\.entry.id).sorted() }
    }

    @discardableResult
    public func store(_ frame: CarriedFrame, origin: CustodyOrigin, now: Int64) -> CustodyStoreResult {
        let current = limits
        let expiresAt: Int64
        switch CustodyRules.admission(of: frame, now: now, limits: current) {
        case .refused(let reason):
            return .refused(reason)
        case .admitted(let at):
            expiresAt = at
        }
        let entry = CustodyRules.Entry(frame.envelope, expiresAt: expiresAt)
        let key = ExactKey(entry.id)
        return state.withLock { state in
            guard state.rows[key] == nil else {
                return .alreadyHeld
            }
            state.rows[key] = Row(frame: frame, entry: entry, origin: origin, receivedAt: now, sequence: state.nextSequence)
            state.nextSequence += 1
            let live = state.live(now: now).map(\.entry)
            let evicted = CustodyRules.evictions(after: entry, among: live, limits: current)
            for id in evicted {
                state.rows[ExactKey(id)] = nil
            }
            return .inserted(entry.id, evicted: evicted)
        }
    }

    public func liveFrames(now: Int64) -> [CarriedFrame] {
        state.withLock { state in
            state.live(now: now)
                .sorted { ($0.receivedAt, $0.sequence) > ($1.receivedAt, $1.sequence) }
                .map(\.frame)
        }
    }

    public func liveIndex(now: Int64) -> [CustodyIndexEntry] {
        state.withLock { state in
            state.live(now: now)
                .sorted { ($0.receivedAt, $0.sequence) > ($1.receivedAt, $1.sequence) }
                .map { CustodyIndexEntry($0.frame) }
        }
    }

    public func liveIds(now: Int64) -> [String] {
        state.withLock { state in
            state.live(now: now).sorted { $0.sequence < $1.sequence }.map(\.entry.id)
        }
    }

    public func frame(_ id: String, now: Int64) -> CarriedFrame? {
        state.withLock { state in
            guard let row = state.rows[ExactKey(id)], row.entry.expiresAt >= now else {
                return nil
            }
            return row.frame
        }
    }

    public func contains(_ id: String) -> Bool {
        state.withLock { $0.rows[ExactKey(id)] != nil }
    }

    public func recipient(of id: String) -> String? {
        state.withLock { $0.rows[ExactKey(id)]?.frame.envelope.recipientId }
    }

    public func remove(_ id: String) {
        state.withLock { $0.rows[ExactKey(id)] = nil }
    }

    /// Drops the expired rows and the oversize ones (`deleteExpired` and `deleteLongerThan`, knit-next #227) in one pass,
    /// each row counted once.
    @discardableResult
    public func sweepExpired(now: Int64) -> Int {
        state.withLock { state in
            let cap = state.limits.maxSignedBytes
            let swept = state.rows.filter { $0.value.entry.expiresAt < now || $0.value.frame.signed.count > cap }.keys
            for key in swept {
                state.rows[key] = nil
            }
            return swept.count
        }
    }
}

extension MemoryCustodyStore: Checkpointing {
    /// Every row and the next insertion order: undoing a unit removes the frames it stored and brings back the ones they
    /// evicted.
    public func checkpoint() -> StoreCheckpoint {
        let held = state.withLock { $0 }
        return StoreCheckpoint { [self] in state.withLock { $0 = held } }
    }
}
