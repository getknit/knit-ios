#if canImport(Darwin)
    import Foundation
    import KnitSync
    import KnitWire
    import Testing

    @testable import KnitMesh
    @testable import KnitSpoolNet

    /// One factory, kept alive for the test: its session ends every socket it opened when it goes.
    final class Dialer {
        let factory = URLSessionSpoolSocketFactory(log: LineLog())

        func open(_ text: String) async throws -> SpoolDial {
            await factory.open(try #require(AcceptedSpoolURL(text, allowCleartext: true)))
        }

        func socket(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> any SpoolSocket {
            guard case .opened(let socket) = try await open(text) else {
                Issue.record("the dial failed", sourceLocation: sourceLocation)
                throw CancellationError()
            }
            return socket
        }

        func failure(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> SpoolDialFailure {
            guard case .failed(let failure) = try await open(text) else {
                Issue.record("the dial opened", sourceLocation: sourceLocation)
                throw CancellationError()
            }
            return failure
        }
    }

    /// A wait with a deadline that never waits on the loser.
    enum SocketRace {
        /// What a cancel or a close may take.
        static let tick: Duration = .seconds(1)

        /// Whether `task` finished within `timeout`. Neither side is awaited past the first: a task that never ends leaves the
        /// test on time.
        static func finishes<Value: Sendable>(_ task: Task<Value, Never>, within timeout: Duration) async -> Bool {
            let first = FirstAnswer()
            return await withCheckedContinuation { continuation in
                first.arm(continuation)
                Task {
                    _ = await task.value
                    first.answer(true)
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    first.answer(false)
                }
            }
        }
    }

    /// The first of two answers, handed to one waiting continuation; the second is dropped.
    final class FirstAnswer: Sendable {
        private enum Phase {
            case open(CheckedContinuation<Bool, Never>?)
            case answered(Bool)
        }

        private let state = Lock(Phase.open(nil))

        func arm(_ continuation: CheckedContinuation<Bool, Never>) {
            let early = state.withLock { phase -> [Bool] in
                guard case .answered(let value) = phase else {
                    phase = .open(continuation)
                    return []
                }
                return [value]
            }
            if let value = early.first {
                continuation.resume(returning: value)
            }
        }

        func answer(_ value: Bool) {
            let waiting = state.withLock { phase -> CheckedContinuation<Bool, Never>? in
                guard case .open(let waiting) = phase else {
                    return nil
                }
                phase = .answered(value)
                return waiting
            }
            waiting?.resume(returning: value)
        }
    }
#endif
