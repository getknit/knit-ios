import KnitStore
import KnitWire

/// The deterministic seal, remembered per (scope, frame) (`SealCache`, `ScopeSync.kt:3324-3334` at knit-next `0832b8462`):
/// sealing is the one per-frame cost of a heal round and its result never changes, so the local blob ids derive on demand
/// and nothing is persisted.
///
/// Custody is filtered with the cheap envelope rule (``ScopeFrames/addressedWithin(_:me:peer:)``) before anything is
/// decoded or sealed, so a full custody of other people's frames costs a scope no AEAD. The frame-set rule's verdict is
/// remembered beside the seal, a refusal included, so a v1 DM between the pair is decoded once. At most ``maxEntries``,
/// least recently used first, keyed by the scope id and the frame id's bytes (`ExactKey`, ADR 2026-09.jc2x).
internal struct ScopeSealCache: Sendable {
    /// The most (scope, frame) verdicts kept (`SEAL_CACHE_MAX`'s role, P3b's design pass).
    static let maxEntries = 2048
    /// How many touches per entry the log keeps before it is compacted.
    private static let touchLogSlack = 4

    private struct Key: Hashable, Sendable {
        let scope: SpoolID
        let frame: ExactKey
    }

    private struct Entry: Sendable {
        let sealed: SealedBlob?
        var touched: Int
    }

    private var entries: [Key: Entry] = [:]
    /// Each touch in order, the stale ones skipped at eviction.
    private var touches: [(key: Key, touched: Int)] = []
    private var head = 0
    private var clock = 0

    /// How many verdicts are kept.
    var count: Int { entries.count }

    /// Every frame of `frames` that may ride `scope`, sealed, in custody's order: what `ScopeSync.held` builds, keyed by
    /// blob id there and in order here.
    mutating func held(_ frames: [CarriedFrame], in scope: SpoolScope, me: NodeId) -> [HeldBlob] {
        frames.compactMap { carried in
            guard ScopeFrames.addressedWithin(carried.envelope, me: me, peer: scope.peer),
                let sealed = verdict(carried, scope: scope, me: me)
            else {
                return nil
            }
            return HeldBlob(sealed: sealed, envelope: carried.envelope)
        }
    }

    private mutating func verdict(_ carried: CarriedFrame, scope: SpoolScope, me: NodeId) -> SealedBlob? {
        let key = Key(scope: scope.id, frame: ExactKey(carried.envelope.id))
        clock += 1
        touches.append((key, clock))
        if let entry = entries[key] {
            entries[key]?.touched = clock
            compactIfNeeded()
            return entry.sealed
        }
        let sealed = ScopeFrames.eligible(carried.envelope, me: me, peer: scope.peer) ? ScopeFrames.seal(carried, into: scope) : nil
        entries[key] = Entry(sealed: sealed, touched: clock)
        evict()
        compactIfNeeded()
        return sealed
    }

    /// Drops the least recently used past the bound.
    private mutating func evict() {
        while entries.count > Self.maxEntries, head < touches.count {
            let oldest = touches[head]
            head += 1
            if entries[oldest.key]?.touched == oldest.touched {
                entries[oldest.key] = nil
            }
        }
    }

    /// Keeps the touch log near the live entries' size.
    private mutating func compactIfNeeded() {
        guard touches.count > Self.touchLogSlack * Self.maxEntries else {
            return
        }
        touches = touches[head...].filter { entries[$0.key]?.touched == $0.touched }
        head = 0
    }
}

/// A custody frame that rides a scope, sealed: its blob id, its blob, and the envelope the push gates read.
internal struct HeldBlob: Sendable, CustomStringConvertible, CustomReflectable {
    let sealed: SealedBlob
    let envelope: RelayEnvelope

    var id: SpoolID { sealed.id }

    var description: String { sealed.description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
