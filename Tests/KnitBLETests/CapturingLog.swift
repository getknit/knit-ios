#if canImport(CoreBluetooth)
    import KnitMesh
    import KnitSync

    /// Bytes that arrive on one thread and are awaited on another.
    ///
    /// Every wait here ends when its task is cancelled, throwing `CancellationError`: Swift Testing's `.timeLimit` cancels
    /// a test's body, and a continuation nobody resumes would otherwise hold the whole run, not fail the one test.
    final class Bytes: Sendable {
        private struct Waiter {
            let id: UInt64
            let count: Int
            let continuation: CheckedContinuation<[UInt8], any Error>
        }

        private struct State {
            var bytes: [UInt8] = []
            var waiters: [Waiter] = []
            var nextWaiter: UInt64 = 0
        }

        private let state = Lock(State())

        var all: [UInt8] { state.withLock { $0.bytes } }

        func append(_ more: [UInt8]) {
            let ready = state.withLock { state -> [(CheckedContinuation<[UInt8], any Error>, [UInt8])] in
                state.bytes += more
                var ready: [(CheckedContinuation<[UInt8], any Error>, [UInt8])] = []
                while let first = state.waiters.first, state.bytes.count >= first.count {
                    state.waiters.removeFirst()
                    ready.append((first.continuation, Array(state.bytes.prefix(first.count))))
                    state.bytes.removeFirst(first.count)
                }
                return ready
            }
            for (continuation, bytes) in ready {
                continuation.resume(returning: bytes)
            }
        }

        /// The next `count` bytes, as soon as they have all arrived, or `CancellationError` once the task is cancelled.
        func take(_ count: Int) async throws -> [UInt8] {
            let id = state.withLock { state in
                state.nextWaiter += 1
                return state.nextWaiter
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], any Error>) in
                    let ready = state.withLock { state -> Result<[UInt8], any Error>? in
                        // A cancel that came before this waiter was kept found nothing to end, so it ends here.
                        if Task.isCancelled {
                            return .failure(CancellationError())
                        }
                        guard state.waiters.isEmpty, state.bytes.count >= count else {
                            state.waiters.append(Waiter(id: id, count: count, continuation: continuation))
                            return nil
                        }
                        let taken = Array(state.bytes.prefix(count))
                        state.bytes.removeFirst(count)
                        return .success(taken)
                    }
                    if let ready {
                        continuation.resume(with: ready)
                    }
                }
            } onCancel: {
                let waiter = state.withLock { state -> Waiter? in
                    guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                        return nil
                    }
                    return state.waiters.remove(at: index)
                }
                waiter?.continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// How many times the link reported its end, and a wait for the first.
    final class Ends: Sendable {
        private struct State {
            var times = 0
            var waiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
            var nextWaiter: UInt64 = 0
        }

        private let state = Lock(State())

        var times: Int { state.withLock { $0.times } }

        func record() {
            let waiters = state.withLock { state in
                state.times += 1
                defer { state.waiters.removeAll() }
                return Array(state.waiters.values)
            }
            for waiter in waiters {
                waiter.resume()
            }
        }

        /// Returns once there has been at least one, or throws `CancellationError` once the task is cancelled.
        func wait() async throws {
            let id = state.withLock { state in
                state.nextWaiter += 1
                return state.nextWaiter
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let ready = state.withLock { state -> Result<Void, any Error>? in
                        if state.times > 0 {
                            return .success(())
                        }
                        if Task.isCancelled {
                            return .failure(CancellationError())
                        }
                        state.waiters[id] = continuation
                        return nil
                    }
                    if let ready {
                        continuation.resume(with: ready)
                    }
                }
            } onCancel: {
                let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
                waiter?.resume(throwing: CancellationError())
            }
        }
    }

    /// A log that keeps its lines, and a wait for one.
    final class CapturingLog: KnitLog {
        private struct Waiter {
            let id: UInt64
            let matches: @Sendable (String) -> Bool
            let continuation: CheckedContinuation<Void, any Error>
        }

        private struct State {
            var lines: [String] = []
            var waiters: [Waiter] = []
            var nextWaiter: UInt64 = 0
        }

        private let state = Lock(State())

        var all: [String] { state.withLock { $0.lines } }

        func log(_: LogLevel, _ message: @autoclosure () -> String) {
            let line = message()
            let ready = state.withLock { state in
                state.lines.append(line)
                let ready = state.waiters.filter { $0.matches(line) }.map(\.continuation)
                state.waiters.removeAll { $0.matches(line) }
                return ready
            }
            for continuation in ready {
                continuation.resume()
            }
        }

        /// Returns once a line `matches`, at once if one already has, or throws `CancellationError` once the task is
        /// cancelled.
        func wait(for matches: @escaping @Sendable (String) -> Bool) async throws {
            let id = state.withLock { state in
                state.nextWaiter += 1
                return state.nextWaiter
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let ready = state.withLock { state -> Result<Void, any Error>? in
                        if state.lines.contains(where: matches) {
                            return .success(())
                        }
                        if Task.isCancelled {
                            return .failure(CancellationError())
                        }
                        state.waiters.append(Waiter(id: id, matches: matches, continuation: continuation))
                        return nil
                    }
                    if let ready {
                        continuation.resume(with: ready)
                    }
                }
            } onCancel: {
                let waiter = state.withLock { state -> Waiter? in
                    guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                        return nil
                    }
                    return state.waiters.remove(at: index)
                }
                waiter?.continuation.resume(throwing: CancellationError())
            }
        }
    }
#endif
