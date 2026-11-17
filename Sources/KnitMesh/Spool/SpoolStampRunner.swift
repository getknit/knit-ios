import Dispatch
import KnitCrypto
import KnitSync

/// A search's stop flag (ADR 2026-11.adrq, P4b2): the `Mesh` actor sets and clears it, and the runner reads it once per
/// ``SpoolPow`` check, every 65,536 counters. A KnitSync ``Lock`` (ADR 2026-09.ahrr), so a clear that races the runner's
/// look is seen whole: the runner either carries on or answers cancelled, which the miner resumes.
internal final class SpoolStopFlag: Sendable {
    private let state = Lock((stopped: false, checks: 0))

    /// Whether the runner should stop; each call is one check.
    func shouldStop() -> Bool {
        state.withLock { state in
            state.checks += 1
            return state.stopped
        }
    }

    /// Sets the flag, or clears it.
    func set(_ stopped: Bool) {
        state.withLock { $0.stopped = stopped }
    }

    /// The checks the runner made so far.
    /// Read by the tests alone, through `@testable`, which `swiftlint analyze` (Sources only) does not see.
    var checks: Int { state.withLock { $0.checks } } // swiftlint:disable:this unused_declaration
}

/// What hashes ``SpoolMinerJob``s off the `Mesh` actor (P4b2): one at a time, each answered exactly once through `done`.
/// Injected, so the tests hand ``Mesh`` a runner of their own.
internal protocol SpoolStampRunner: Sendable {
    /// Hashes `job` from its counter, asking `stop` at every check, and calls `done` once with what the search answered.
    func run(_ job: SpoolMinerJob, stop: SpoolStopFlag, done: @escaping @Sendable (SpoolPow.Search) -> Void)
    /// Returns once every search handed over so far has returned, blocking no thread while it waits.
    func drain() async
}

/// The runner a mesh makes on its first search: one serial `DispatchQueue` per engine, never the cooperative pool, a detached
/// task or the actor, since a search holds its thread for up to 2^26 hashes. `.utility` asks the system to favour the
/// interface over it; Linux ignores the QoS.
internal final class DispatchStampRunner: SpoolStampRunner {
    private let queue = DispatchQueue(label: "app.getknit.knit.spool.miner", qos: .utility)

    func run(_ job: SpoolMinerJob, stop: SpoolStopFlag, done: @escaping @Sendable (SpoolPow.Search) -> Void) {
        queue.async {
            done(SpoolPow.mine(scopeId: job.scope.bytes, day: job.day, bits: job.bits, from: job.from, shouldStop: stop.shouldStop))
        }
    }

    func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                continuation.resume()
            }
        }
    }
}
