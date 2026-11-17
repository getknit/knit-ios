import Foundation
import KnitSync

/// Wakes whoever waits on the stub's state: a test's async wait, with a deadline, or a connection's thread.
final class StubEvents: Sendable {
    private struct State {
        var serial = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var next = 0
    }

    private let state = Lock(State())
    private let condition = NSCondition()

    /// Something changed: every waiter looks again.
    func changed() {
        let waiters = state.withLock { state in
            state.serial += 1
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiters {
            waiter.resume()
        }
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    /// Waits until `holds` answers true, at most `timeout`; answers whether it did.
    func wait(within timeout: Duration, until holds: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !holds() {
            guard ContinuousClock.now < deadline else {
                return false
            }
            let token = state.withLock { state in
                defer { state.next += 1 }
                return state.next
            }
            let seen = state.withLock { $0.serial }
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    guard state.serial == seen else {
                        return true
                    }
                    state.waiters[token] = continuation
                    return false
                }
                if resumeNow {
                    continuation.resume()
                    return
                }
                // The deadline: resumes the waiter if no change did first.
                Task { [state] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    state.withLock { $0.waiters.removeValue(forKey: token) }?.resume()
                }
            }
        }
        return true
    }

    /// Blocks the calling thread until `holds` answers true. Only a connection's own thread calls it.
    func blockingWait(until holds: () -> Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !holds() {
            condition.wait()
        }
        return true
    }
}
