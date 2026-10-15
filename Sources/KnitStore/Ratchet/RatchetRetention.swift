public import KnitWire

/// The ratchet's retention sweep as pure decisions that ``MemoryRatchetStore`` and the SQL store both apply, as
/// ``CustodyRules`` serves custody (`RatchetRepository.sweep`, `sweepLocalEpochs` and their constants, knit-next
/// `data/ratchet/RatchetRepository.kt:121-157` and `:213-224`, at `ac491f4c`). What the sweep deletes is what a later
/// compromise of the device can no longer open: the forward-secrecy window. Sessions are never swept.
///
/// The rules are local, so the pair never compares them, but the two stores must agree, and where Android leaves an
/// order to SQLite this gives it a key of its own.
public enum RatchetRetention {
    /// How long a skipped key lives from its creation: twice custody's 24 h, for late re-serves and clock skew
    /// (`SKIPPED_TTL_MS`).
    public static let skippedKeyMilliseconds: Int64 = 172_800_000
    /// How long a receive chain lives unused (`RECV_EPOCH_TTL_MS`).
    public static let receiveChainMilliseconds: Int64 = 172_800_000
    /// The most skipped keys held in all, a bound on what a peer can make us store rather than on correctness: an evicted
    /// key is one late frame lost (`MAX_SKIPPED_KEYS`).
    public static let maxSkippedKeys = 2000
    /// Our newest epochs for a peer that always stay, so a peer epoch in flight on a recent one keeps opening
    /// (`KEEP_NEWEST_LOCAL_EPOCHS`).
    public static let keptLocalEpochs = 3
    /// The most of our epochs kept for one peer (`MAX_LOCAL_EPOCHS`).
    public static let maxLocalEpochs = 16
    /// How long after its mint an epoch the peer has moved past is kept, for re-serves still based on it
    /// (`LOCAL_EPOCH_RETIRE_MS`).
    public static let localEpochRetireMilliseconds: Int64 = 172_800_000
    /// How long after its mint any epoch is kept at most (`LOCAL_EPOCH_HARD_TTL_MS`).
    public static let localEpochLifetimeMilliseconds: Int64 = 2_592_000_000

    /// A skipped key created before this goes (`deleteSkippedKeysBefore(now - SKIPPED_TTL_MS)`), wrapping as Kotlin's
    /// `Long` does.
    public static func skippedKeyCutoff(now: Int64) -> Int64 {
        now &- skippedKeyMilliseconds
    }

    /// A receive chain last used before this goes (`deleteRecvEpochsBefore(now - RECV_EPOCH_TTL_MS)`).
    public static func receiveChainCutoff(now: Int64) -> Int64 {
        now &- receiveChainMilliseconds
    }

    /// How many of `count` skipped keys, every one held once the expired are gone, the cap evicts (`countSkippedKeys() -
    /// MAX_SKIPPED_KEYS`).
    public static func skippedKeyExcess(count: Int) -> Int {
        max(0, count - maxSkippedKeys)
    }

    /// The skipped keys the cap evicts from `keys`, every one held once the expired are gone: the oldest beyond
    /// ``maxSkippedKeys`` (`evictOldestSkippedKeys`, `RatchetDao.kt:110-115`). Android orders by `createdAt` alone and
    /// leaves a tie to SQLite; here a tie goes by peer, epoch, index and root tag, so both stores evict the same keys.
    public static func evictedSkippedKeys(_ keys: [RatchetSkippedKeyStamp]) -> [RatchetSkippedKeyStamp] {
        Array(keys.sorted(by: evictsFirst).prefix(skippedKeyExcess(count: keys.count)))
    }

    /// Whether `lhs` goes before `rhs` when the cap evicts: older first, then by peer (as bytes, which is how a node id
    /// orders), epoch, index and root tag.
    static func evictsFirst(_ lhs: RatchetSkippedKeyStamp, _ rhs: RatchetSkippedKeyStamp) -> Bool {
        (lhs.createdAt, lhs.peer, lhs.epoch, lhs.index, lhs.rootTag) < (rhs.createdAt, rhs.peer, rhs.epoch, rhs.index, rhs.rootTag)
    }

    /// The numbers of our epochs for one peer that retire (`sweepLocalEpochs`, `RatchetRepository.kt:141-157`). Ranked
    /// the most recently minted first, never by number: a reset restarts the numbering, and ranking by number let a
    /// long-lived session's dead-era rows outrank every live one, so the cap deleted each fresh epoch within a sweep and
    /// the pair relapsed on the reset floor's cadence (knit-next ADR 027). The newest ``keptLocalEpochs`` always stay; of
    /// the rest an epoch goes past the cap of ``maxLocalEpochs``, at ``localEpochLifetimeMilliseconds``, or once the peer
    /// has sealed against a newer one (`highestPeAcked`) and ``localEpochRetireMilliseconds`` have passed since its mint.
    public static func retiredLocalEpochs(_ epochs: [(epoch: Int, createdAt: Int64)], highestPeAcked: Int, now: Int64) -> [Int] {
        // `ORDER BY createdAt DESC, epoch DESC` (`RatchetDao.kt:51`): the number orders only rows minted in one millisecond.
        let newestFirst = epochs.sorted { lhs, rhs in (lhs.createdAt, lhs.epoch) > (rhs.createdAt, rhs.epoch) }
        return newestFirst.dropFirst(keptLocalEpochs).enumerated().filter { dropped, epoch in
            let age = now &- epoch.createdAt
            let overCap = keptLocalEpochs + dropped >= maxLocalEpochs
            let expired = age >= localEpochLifetimeMilliseconds
            let retired = epoch.epoch < highestPeAcked && age >= localEpochRetireMilliseconds
            return overCap || expired || retired
        }
        .map(\.element.epoch)
    }
}

/// A skipped key as the retention cap weighs it: its full key and its age, no key material.
public struct RatchetSkippedKeyStamp: Hashable, Sendable {
    /// The peer it was derived for.
    public var peer: NodeId
    /// The peer's epoch number.
    public var epoch: Int
    /// The chain index.
    public var index: Int
    /// The local tag of the root that derived it.
    public var rootTag: Int64
    /// When it was derived, on our clock.
    public var createdAt: Int64

    /// A stamp.
    public init(peer: NodeId, epoch: Int, index: Int, rootTag: Int64, createdAt: Int64) {
        self.peer = peer
        self.epoch = epoch
        self.index = index
        self.rootTag = rootTag
        self.createdAt = createdAt
    }
}
