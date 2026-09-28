import Foundation
import KnitSync
import Testing

/// `Lock`: one thread at a time, errors passed through, and the lock given back however the body ends. The TSan
/// gate runs these too, which is the check that it sees this lock where it could not see `Mutex` (ADR 2026-09.ahrr).
@Suite(.timeLimit(.minutes(1))) struct LockTests {
    private struct Refused: Error, Equatable {}

    @Test func threadsTakeTurns() async {
        let counter = Lock(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<1000 {
                        counter.withLock { $0 += 1 }
                    }
                }
            }
        }
        #expect(counter.withLock { $0 } == 8000)
    }

    @Test func realThreadsTakeTurnsToo() {
        // Tasks share a small pool; plain threads make sure two bodies really do run at once without the lock.
        let counter = Lock([Int]())
        let done = DispatchGroup()
        for thread in 0..<4 {
            done.enter()
            Thread.detachNewThread {
                for step in 0..<500 {
                    counter.withLock { $0.append(thread * 1000 + step) }
                }
                done.leave()
            }
        }
        done.wait()
        let seen = counter.withLock { $0 }
        #expect(seen.count == 2000)
        #expect(Set(seen).count == 2000)
    }

    @Test func aThrownErrorReachesTheCallerAndFreesTheLock() {
        let lock = Lock("before")
        #expect(throws: Refused()) {
            try lock.withLock { value throws(Refused) in
                value = "changed"
                throw Refused()
            }
        }
        #expect(lock.withLock { $0 } == "changed", "a change made before the throw stays, as with Mutex")
    }

    @Test func theBodysResultComesBack() {
        let lock = Lock([1, 2, 3])
        let sum = lock.withLock { $0.reduce(0, +) }
        #expect(sum == 6)
    }
}
