import Foundation
import GRDB
public import KnitStore
import KnitSync

extension KnitDatabase {
    /// The store unit open on the writer's connection: how many units deep, whether a store failed inside it, and the
    /// thread running it. A unit holds the writer's queue from its first statement to its end, so only its own thread
    /// reaches the connection while it is open.
    struct OpenUnit {
        var depth = 0
        var failed = false
        var thread: ObjectIdentifier?
    }

    /// Whether the calling thread runs inside the open unit. Only the unit's own thread reads inside it: every other
    /// reader keeps its snapshot of what is committed.
    var unitRunsOnThisThread: Bool {
        guard let thread = unit.withLock(\.thread) else {
            return false
        }
        return thread == ObjectIdentifier(Thread.current)
    }

    /// A store's write inside the unit, on the writer's queue: in a savepoint of its own, so a write that fails leaves
    /// nothing of itself behind, and its error fails the unit. Once the unit has failed nothing more runs in it, and
    /// nothing more is reported.
    func writeInUnit<T>(_ db: Database, or fallback: T, _ updates: (Database) throws -> T) -> T {
        guard !unit.withLock(\.failed) else {
            return fallback
        }
        var value = fallback
        do {
            try db.inSavepoint {
                value = try updates(db)
                return .commit
            }
        } catch {
            failUnit(with: error)
            return fallback
        }
        return value
    }

    /// A store's read inside the unit: on the unit's own connection, so it sees what the unit wrote, which a snapshot on
    /// one of the pool's readers never would. Its error fails the unit, since the body would go on to decide on the
    /// fallback.
    func readInUnit<T>(or fallback: T, _ value: (Database) throws -> T) -> T {
        guard !unit.withLock(\.failed) else {
            return fallback
        }
        do {
            return try writer.unsafeReentrantRead(value)
        } catch {
            failUnit(with: error)
            return fallback
        }
    }

    /// Fails the open unit, and reports `error` unless the unit had already failed: one report for each unit, the error
    /// that failed it.
    private func failUnit(with error: any Error) {
        let first = unit.withLock { unit in
            let first = !unit.failed
            unit.failed = true
            return first
        }
        if first {
            report(error)
        }
    }

    /// Opens one more level of the unit, on the writer's queue, and answers how deep it is, 1 for the outermost, or nil
    /// when the unit it would join has failed.
    private func enterUnit() -> Int? {
        let thread = ObjectIdentifier(Thread.current)
        return unit.withLock { unit in
            guard unit.depth == 0 || !unit.failed else {
                return nil
            }
            if unit.depth == 0 {
                unit.thread = thread
            }
            unit.depth += 1
            return unit.depth
        }
    }

    /// Closes one level of the unit; closing the outermost leaves no unit open.
    private func leaveUnit() {
        unit.withLock { unit in
            unit.depth -= 1
            if unit.depth == 0 {
                unit = OpenUnit()
            }
        }
    }
}

// The unit is one write transaction on the writer's connection, with a savepoint for each unit nested in it and for each
// store write inside it. What it rests on, in GRDB 7.11.1 (`.build/checkouts/GRDB.swift/GRDB/Core`):
// - `write` is `writeWithoutTransaction` around `inTransaction` (DatabaseWriter.swift:416-425), and
//   `writeWithoutTransaction` is `SerializedDatabase.sync` (DatabaseQueue.swift:395-397, DatabasePool.swift:784-786),
//   which traps when it is called on its own queue (SerializedDatabase.swift:106-145). A store's own transaction cannot
//   open inside a unit.
// - `inTransaction` cannot nest (Database.swift:1496-1563). `inSavepoint` can, and opens the transaction itself when
//   none is open (Database.swift:1625-1711), IMMEDIATE on a connection that writes (Database.swift:1723-1735).
// - `unsafeReentrantWrite` is `SerializedDatabase.reentrantSync`, which runs inline on the writer's queue and leaves an
//   open transaction alone (DatabaseQueue.swift:460-462, DatabasePool.swift:886-888, SerializedDatabase.swift:167-228).
//   From any other thread it waits for the queue.
// - `DatabaseQueue.read` is `SerializedDatabase.sync` too, so it traps inside a unit (DatabaseQueue.swift:228-234), and
//   `DatabasePool.read` reads on a reader connection, which cannot see the unit's uncommitted rows
//   (DatabasePool.swift:339-352). `unsafeReentrantRead` reads on the writer's connection when it is called on the
//   writer's queue (DatabasePool.swift:478-493, DatabaseQueue.swift:292-294).
// - Once SQLite has rolled a transaction back by itself, every later statement inside it throws SQLITE_ABORT before it
//   runs (Database.swift:1465-1478, Database+Statements.swift:440-443), and so does its commit. Its rollback throws
//   nothing, since no transaction is left to roll back (Database.swift:1743-1790).
extension KnitDatabase: StoreTransactor {
    public func atomically<Value>(_ body: () -> Value?) -> Transacted<Value> {
        writer.unsafeReentrantWrite { db -> Transacted<Value> in
            guard let depth = enterUnit() else {
                return .failed
            }
            defer { leaveUnit() }
            var outcome = Transacted<Value>.abandoned
            do {
                try db.inSavepoint {
                    let value = body()
                    // The failure first, whatever the body answered: after SQLite's own rollback nothing below would throw,
                    // so a nil read first would answer a failed unit as abandoned.
                    guard !unit.withLock(\.failed) else {
                        outcome = .failed
                        return .rollback
                    }
                    guard let value else {
                        return .rollback
                    }
                    // Only the outermost commit makes the writes stand, so a nested unit has only joined it.
                    outcome = depth > 1 ? .joined(value) : .committed(value)
                    return .commit
                }
            } catch {
                // Its BEGIN, savepoint, commit or rollback failed, or SQLite rolled it back by itself: nothing of it stands.
                failUnit(with: error)
                return .failed
            }
            return outcome
        }
    }
}
