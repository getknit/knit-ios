public import KnitWire

/// The group form's retention sweep and its retired row, as pure decisions that ``MemoryGroupRatchetStore`` and the SQL
/// store both apply, as ``RatchetRetention`` serves the DM ratchet (`GroupRatchetRepository.sweep`, `sweepSendChains`,
/// `retireSendChains` and their constants, knit-next `data/ratchet/GroupRatchetRepository.kt:42-46` and `:154-236`, at
/// `cbf2a487`). What the sweep deletes is what a later compromise of the device can no longer open.
///
/// The rules are local, so the pair never compares them, but the two stores must agree, and where Android leaves an
/// order to SQLite this gives it a key of its own.
public enum GroupRatchetRetention {
    /// How long a skipped key lives from its creation: twice custody's 24 h, as the DM's (`SKIPPED_TTL_MS`).
    public static let skippedKeyMilliseconds: Int64 = 172_800_000
    /// How long a receive chain lives unused (`RECV_CHAIN_TTL_MS`).
    public static let receiveChainMilliseconds: Int64 = 172_800_000
    /// The most group skipped keys held in all: a budget of its own, apart from the DM's 2,000 (`MAX_SKIPPED_KEYS`). An
    /// evicted key is one late frame lost.
    public static let maxSkippedKeys = 2000
    /// How long a superseded send seed stays, past its successor's mint, for a key request a frame still re-served from
    /// custody needs (`PREV_SEED_RETAIN_MS`).
    public static let previousSeedMilliseconds: Int64 = 172_800_000
    /// A retired chain's count: the engine's cap, `GroupRatchetEngine.maxEpochMessages` (`MAX_EPOCH_MESSAGES`), so the
    /// next seal mints past it. KnitStore does not depend on KnitCrypto; a test holds the two equal.
    public static let retiredCount = 200

    /// A skipped key created before this goes (`deleteSkippedKeysBefore(now - SKIPPED_TTL_MS)`), wrapping as Kotlin's `Long`
    /// does.
    public static func skippedKeyCutoff(now: Int64) -> Int64 {
        now &- skippedKeyMilliseconds
    }

    /// A receive chain last used before this goes (`deleteRecvChainsBefore(now - RECV_CHAIN_TTL_MS)`).
    public static func receiveChainCutoff(now: Int64) -> Int64 {
        now &- receiveChainMilliseconds
    }

    /// How many of `count` skipped keys, every one held once the expired are gone, the cap evicts (`countSkippedKeys() -
    /// MAX_SKIPPED_KEYS`).
    public static func skippedKeyExcess(count: Int) -> Int {
        max(0, count - maxSkippedKeys)
    }

    /// The skipped keys the cap evicts from `keys`, every one held once the expired are gone: the oldest beyond
    /// ``maxSkippedKeys`` (`evictOldestSkippedKeys`, `GroupRatchetDao.kt:92-96`). Android orders by `createdAt` alone and
    /// leaves a tie to SQLite; here a tie goes by group, as bytes, then sender, epoch, mint and index, so both stores evict
    /// the same keys.
    public static func evictedSkippedKeys(_ keys: [GroupSkippedKeyStamp]) -> [GroupSkippedKeyStamp] {
        Array(keys.sorted(by: evictsFirst).prefix(skippedKeyExcess(count: keys.count)))
    }

    /// Whether `lhs` goes before `rhs` when the cap evicts: older first, then by group (its bytes, which is how SQLite
    /// orders the column), sender (as bytes, which is how a node id orders), epoch, mint and index.
    static func evictsFirst(_ lhs: GroupSkippedKeyStamp, _ rhs: GroupSkippedKeyStamp) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        if lhs.group != rhs.group {
            return lhs.group.bytes.lexicographicallyPrecedes(rhs.group.bytes)
        }
        return (lhs.sender, lhs.epoch, lhs.mintedAt, lhs.index) < (rhs.sender, rhs.epoch, rhs.mintedAt, rhs.index)
    }

    /// The lowest epoch of ours a group keeps at `now`, given its newest send chain's `epoch` and `mintedAt`; every chain
    /// below it goes (`sweepSendChains`, `GroupRatchetRepository.kt:162-181`). The newest always stays: it is the sealing
    /// epoch and the source of every re-distribution, and a retired newest row holds the number the next mint must pass,
    /// however old, so numbering only rises but after a wipe. The previous one drains for ``previousSeedMilliseconds``
    /// past the newest's mint, for key requests from frames custody still re-serves; a retired previous row drains alike.
    public static func lowestKeptEpoch(newest epoch: Int, mintedAt: Int64, now: Int64) -> Int {
        now &- mintedAt < previousSeedMilliseconds ? epoch - 1 : epoch
    }

    /// `chain` with every key gone and its epoch spent, its number and mint kept: what a forced rekey, a leave and a delete
    /// leave of our newest epoch (`SendChain.retired`, `GroupRatchetEngine.kt:48-56`; knit-next ADR 2026-10.xgwj).
    public static func retired(_ chain: GroupSendChainRecord) -> GroupSendChainRecord {
        GroupSendChainRecord(epoch: chain.epoch, seed: [], chainKey: [], count: retiredCount, mintedAt: chain.mintedAt)
    }
}

/// A group skipped key as the retention cap weighs it: its full key and its age, no key material.
public struct GroupSkippedKeyStamp: Hashable, Sendable {
    /// The group, by its bytes.
    public var group: ExactKey
    /// The sender whose chain banked it.
    public var sender: NodeId
    /// The sender's epoch number.
    public var epoch: Int
    /// The mint of the chain that banked it.
    public var mintedAt: Int64
    /// The chain index.
    public var index: Int
    /// When it was banked, on our clock.
    public var createdAt: Int64

    /// A stamp.
    public init(group: ExactKey, sender: NodeId, epoch: Int, mintedAt: Int64, index: Int, createdAt: Int64) {
        self.group = group
        self.sender = sender
        self.epoch = epoch
        self.mintedAt = mintedAt
        self.index = index
        self.createdAt = createdAt
    }
}
