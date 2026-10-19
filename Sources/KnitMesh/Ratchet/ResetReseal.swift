import KnitWire

/// The second pass a peer's reset owes its re-seal (knit-next ADR 2026-10.dmgw, #171; `pendingSecondReseal`,
/// `resealSecondPass` and `ResetReseal` in `MeshManager.kt:3912-3990`, `:4139-4150` at `4f3cd995`), held in memory.
///
/// The re-seal keeps each DM's original id, so it reaches only what it meets live past each router's ten-minute window:
/// a relay that saw the original inside its window drops the copy, and every custody keeps only the original. For the
/// DMs whose failures fired the reset, that is every relay between the pair. So the ids a reset re-sealed are recorded,
/// per peer, before the first copy leaves, and sealed once more ``secondPassMilliseconds`` later, those still unacked
/// only. A later reset of the same peer replaces its entry, and the second pass records nothing, so it never re-arms: a
/// loop would spend a chain key per DM every eleven minutes.
///
/// The clock is the engine's monotonic one, which the router's ``SeenSet`` reads, so the two windows move together, as
/// Kotlin ties the second pass to `SeenSet.DEFAULT_TTL_MS` on the clock its router reads. A process that ends inside the
/// window loses the pass, as Kotlin's does.
internal struct ResetReseal {
    /// How long after a reset's re-seal its second pass is due: the routers' dedup window and one 60-second tick, so a
    /// relay that dropped the first copy as a duplicate of the original has forgotten the id (`SECOND_PASS_MS`,
    /// `MeshManager.kt:4149`).
    static let secondPassMilliseconds = SeenSet.defaultWindowMilliseconds + reofferTickMilliseconds
    /// The re-offer's tick, `MeshConfiguration.reofferMilliseconds`'s default, which Kotlin's `60_000L` there names.
    private static let reofferTickMilliseconds: Int64 = 60_000

    /// One reset's re-seal, owed a second pass at `dueAt`.
    struct Pass: Equatable {
        let dueAt: Int64
        /// The DM ids the first pass took, by their bytes (ADR 2026-09.jc2x).
        let ids: Set<ExactKey>
    }

    /// The pass owed each peer; read by the tests, which pin what a reset recorded.
    private(set) var pending: [NodeId: Pass] = [:]

    /// Records the ids a reset of `peer` re-seals now, at `now` on the monotonic clock, replacing any pass still owed for
    /// that peer. None recorded leaves a pending pass as it was (`if (rows.isNotEmpty())`, `:3939-3941`).
    mutating func record(_ ids: [String], for peer: NodeId, now: Int64) {
        guard !ids.isEmpty else {
            return
        }
        pending[peer] = Pass(dueAt: now &+ Self.secondPassMilliseconds, ids: Set(ids.map(ExactKey.init)))
    }

    /// Takes every pass due at `now`, removed before it runs, so a failure costs that pass and never repeats it; in node id
    /// order, so the re-seals go out in an order a test can read.
    mutating func takeDue(now: Int64) -> [(peer: NodeId, ids: Set<ExactKey>)] {
        let due = pending.filter { now >= $0.value.dueAt }.sorted { $0.key < $1.key }
        for (peer, _) in due {
            pending[peer] = nil
        }
        return due.map { (peer: $0.key, ids: $0.value.ids) }
    }
}
