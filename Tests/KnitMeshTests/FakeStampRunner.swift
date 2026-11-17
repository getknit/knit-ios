import KnitCrypto
import KnitSync
import Testing

@testable import KnitMesh

/// A stamp runner the test drives (ADR 2026-11.adrq, P4b2): it holds every job until the test releases it, as a runner
/// whose thread is busy would, and then posts through the mesh's own `done`, so the mesh's post path runs as it does with
/// the real runner. Nothing here hashes at 24 bits.
final class FakeStampRunner: SpoolStampRunner {
    struct Held {
        let job: SpoolMinerJob
        let stop: SpoolStopFlag
        let done: @Sendable (SpoolPow.Search) -> Void
    }

    private let state = Lock((held: [Held](), started: [SpoolMinerJob]()))

    func run(_ job: SpoolMinerJob, stop: SpoolStopFlag, done: @escaping @Sendable (SpoolPow.Search) -> Void) {
        state.withLock { state in
            state.held.append(Held(job: job, stop: stop, done: done))
            state.started.append(job)
        }
    }

    /// Nothing runs off the test's own thread, so nothing is left to wait for.
    func drain() async {
        await Task.yield()
    }

    /// Every job started, oldest first.
    var started: [SpoolMinerJob] { state.withLock { $0.started } }
    /// The jobs held now.
    var held: [SpoolMinerJob] { state.withLock { $0.held.map(\.job) } }
    /// Whether the oldest held job's stop flag is set, as the runner would read it at its next check.
    var stopAsked: Bool {
        let flag = state.withLock { $0.held.first?.stop }
        return flag?.shouldStop() == true
    }

    /// Returns the oldest held job with `search`, or with what ``SpoolPow`` answers from its counter when `search` is `nil`:
    /// the stop flag is read from the check after `skippedChecks`, so a search already past its first check sees a stop set
    /// before it is released. Answers the job.
    @discardableResult
    func release(_ search: SpoolPow.Search? = nil, skippedChecks: Int = 0) -> SpoolMinerJob? {
        let next = state.withLock { state -> Held? in state.held.isEmpty ? nil : state.held.removeFirst() }
        guard let next else {
            return nil
        }
        var checks = 0
        let job = next.job
        let result =
            search
            ?? SpoolPow.mine(scopeId: job.scope.bytes, day: job.day, bits: job.bits, from: job.from) {
                checks += 1
                return checks > skippedChecks && next.stop.shouldStop()
            }
        next.done(result)
        return job
    }
}

extension SpoolMeshRig {
    /// Waits, yielding, until `condition` holds; records an issue when it never does within the polls `settle` allows.
    func until(polls: Int = 200_000, _ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<polls {
            if await condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("the condition never held", sourceLocation: sourceLocation)
    }
}
