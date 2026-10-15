import KnitSync

/// The store unit over stores in memory, for knit-peer, the tests and the demo (``StoreTransactor``).
///
/// Every unit, the outermost and each one nested in it, checkpoints every store as it opens and puts them all back if it
/// abandons or fails. So a nested unit that abandons undoes only its own writes, as a savepoint does on the database,
/// and a failure undoes everything since the outermost opened. Memory never fails on its own: ``failCurrentUnit()`` is
/// how a test's failing store double fails a unit, as a database error would.
///
/// Its units come from one caller at a time, the engine on its actor, since the memory stores serve one engine. A store
/// written from another thread while a unit is open loses that write if the unit is undone, where the database would
/// run it after the unit, in a transaction of its own.
public final class MemoryTransactor: StoreTransactor {
    private struct Unit {
        /// How many units are open: the outermost, and those nested in it.
        var depth = 0
        /// Whether a store failed inside the open unit.
        var failed = false
    }

    private let stores: [any Checkpointing]
    private let unit = Lock(Unit())

    /// The unit over `stores`, which must be every store a unit may write: one left out keeps its writes when a unit is
    /// undone.
    public init(stores: [any Checkpointing]) {
        self.stores = stores
    }

    public func atomically<Value>(_ body: () -> Value?) -> Transacted<Value> {
        guard !unit.withLock({ $0.depth > 0 && $0.failed }) else {
            return .failed
        }
        let saved = stores.map { $0.checkpoint() }
        let depth = unit.withLock { unit in
            unit.depth += 1
            return unit.depth
        }
        let value = body()
        let failed = unit.withLock { unit in
            let failed = unit.failed
            unit.depth -= 1
            if unit.depth == 0 {
                unit.failed = false
            }
            return failed
        }
        // A failure fails the unit whatever the body answered: a nil after one is no abandon.
        guard !failed, let value else {
            for checkpoint in saved {
                checkpoint.restore()
            }
            return failed ? .failed : .abandoned
        }
        // Only the outermost unit's end makes the writes stand, so a nested unit has only joined it.
        return depth > 1 ? .joined(value) : .committed(value)
    }

    /// Fails the open unit, as a database error inside one does. Outside a unit it does nothing, as a store's error
    /// outside one fails nothing. Only a failing store double calls it, in a test: memory stores never fail.
    public func failCurrentUnit() {
        unit.withLock { unit in
            if unit.depth > 0 {
                unit.failed = true
            }
        }
    }
}
