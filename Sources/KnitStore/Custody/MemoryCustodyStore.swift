import KnitWire
import Synchronization

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
        var rows: [ExactKey: Row] = [:]
        var nextSequence = 0

        func live(now: Int64) -> [Row] {
            rows.values.filter { $0.entry.expiresAt >= now }
        }
    }

    private let limits: CustodyLimits
    private let state = Mutex(State())

    /// An empty store with knit-next's limits unless told otherwise.
    public init(limits: CustodyLimits = CustodyLimits()) {
        self.limits = limits
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
    public func store(_ frame: CarriedFrame, origin: CustodyOrigin, now: Int64) -> Bool {
        guard let expiresAt = CustodyRules.expiry(of: frame.envelope, now: now, limits: limits) else {
            return false
        }
        let entry = CustodyRules.Entry(frame.envelope, expiresAt: expiresAt)
        let key = ExactKey(entry.id)
        state.withLock { state in
            guard state.rows[key] == nil else {
                return
            }
            state.rows[key] = Row(frame: frame, entry: entry, origin: origin, receivedAt: now, sequence: state.nextSequence)
            state.nextSequence += 1
            let live = state.live(now: now).map(\.entry)
            for id in CustodyRules.evictions(after: entry, among: live, limits: limits) {
                state.rows[ExactKey(id)] = nil
            }
        }
        return true
    }

    public func liveFrames(now: Int64) -> [CarriedFrame] {
        state.withLock { state in
            state.live(now: now)
                .sorted { ($0.receivedAt, $0.sequence) > ($1.receivedAt, $1.sequence) }
                .map(\.frame)
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

    @discardableResult
    public func sweepExpired(now: Int64) -> Int {
        state.withLock { state in
            let expired = state.rows.filter { $0.value.entry.expiresAt < now }.keys
            for key in expired {
                state.rows[key] = nil
            }
            return expired.count
        }
    }
}
