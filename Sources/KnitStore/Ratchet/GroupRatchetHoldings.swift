public import KnitWire

/// One of our send epochs for a group as a ``GroupRatchetStore`` keeps it (`GroupSendChainEntity`, knit-next
/// `data/ratchet/GroupRatchetEntities.kt:6-30`), keyed by the group and the epoch: the engine's `SendChain` field for
/// field, as bytes and numbers, since KnitStore does not depend on KnitCrypto (`GroupRatchetRecords` in KnitMesh maps
/// them). Deleting these rows is the sender's forward secrecy.
///
/// Two of the entity's columns are left out, as the DM session leaves them out: `export`, the spool's half (ADR
/// 2026-10.5sk9), and `updatedAt`, a stamp nothing reads.
public struct GroupSendChainRecord: Sendable, Equatable {
    /// The epoch's number.
    public var epoch: Int
    /// The epoch's seed, empty for a retired chain. A secret.
    public var seed: [UInt8]
    /// The chain key the next seal spends, empty for a retired chain. A secret.
    public var chainKey: [UInt8]
    /// How many frames the epoch has sealed.
    public var count: Int
    /// When it was minted, on our clock.
    public var mintedAt: Int64

    /// A send chain's row.
    public init(epoch: Int, seed: [UInt8], chainKey: [UInt8], count: Int, mintedAt: Int64) {
        self.epoch = epoch
        self.seed = seed
        self.chainKey = chainKey
        self.count = count
        self.mintedAt = mintedAt
    }

    /// Whether a forced rekey retired it: judged on the empty seed, never on the count (`SendChain.isRetired`,
    /// `GroupRatchetEngine.kt:41-46`; knit-next ADR 2026-10.xgwj).
    public var isRetired: Bool {
        seed.isEmpty
    }
}

/// One sender's receive chain for one epoch and mint (`GroupRecvChainEntity`, `GroupRatchetEntities.kt:32-51`), keyed by
/// the group, the sender, the epoch and `mintedAt`, so a wiped sender's re-mint of a number sits beside the draining
/// old era. The sender and the group are the store call's; the seed is never kept.
public struct GroupRecvChainRecord: Sendable, Equatable {
    /// The sender's epoch number.
    public var epoch: Int
    /// When the sender minted it, on the sender's clock.
    public var mintedAt: Int64
    /// The chain key at ``next``. A secret.
    public var chainKey: [UInt8]
    /// The next index the chain has not spent.
    public var next: Int
    /// When it last opened a frame, on our clock.
    public var lastUsedAt: Int64

    /// A receive chain's row.
    public init(epoch: Int, mintedAt: Int64, chainKey: [UInt8], next: Int, lastUsedAt: Int64) {
        self.epoch = epoch
        self.mintedAt = mintedAt
        self.chainKey = chainKey
        self.next = next
        self.lastUsedAt = lastUsedAt
    }
}

/// A stored out-of-order message key (`GroupSkippedKeyEntity`, `GroupRatchetEntities.kt:53-67`), keyed by the group, the
/// sender, the epoch, the mint and the index, inserted only where none is stored, and spent by that full key.
public struct GroupSkippedKeyRecord: Sendable, Equatable {
    /// The sender's epoch number.
    public var epoch: Int
    /// The mint of the chain that banked it.
    public var mintedAt: Int64
    /// The chain index it opens, Kotlin's `idx`.
    public var index: Int
    /// The message key. A secret.
    public var messageKey: [UInt8]
    /// When it was banked, on our clock.
    public var createdAt: Int64

    /// A skipped key's row.
    public init(epoch: Int, mintedAt: Int64, index: Int, messageKey: [UInt8], createdAt: Int64) {
        self.epoch = epoch
        self.mintedAt = mintedAt
        self.index = index
        self.messageKey = messageKey
        self.createdAt = createdAt
    }
}

/// One member's row in a group's seed outbox (`GroupKeySendEntity` and `GroupKeySendState`, `GroupRatchetEntities.kt:69-86`
/// and `GroupRatchetStore.kt:3-17`), keyed by the group and the member. It, not custody, is the truth for whether the member
/// holds our current epoch: the newest distribution we tried, and the newest the member acknowledged adopting. Both epochs
/// only rise, and the row goes with the member's departure or the group's leave or delete.
public struct GroupKeySendRecord: Sendable, Equatable {
    /// The member.
    public var member: NodeId
    /// The newest epoch we sent the member.
    public var sentEpoch: Int
    /// When we last sent one, on our clock.
    public var sentAt: Int64
    /// The newest epoch the member acknowledged, 0 for none.
    public var ackedEpoch: Int
    /// When it did, on our clock, 0 for never.
    public var ackedAt: Int64

    /// An outbox row.
    public init(member: NodeId, sentEpoch: Int, sentAt: Int64, ackedEpoch: Int, ackedAt: Int64) {
        self.member = member
        self.sentEpoch = sentEpoch
        self.sentAt = sentAt
        self.ackedEpoch = ackedEpoch
        self.ackedAt = ackedAt
    }
}

/// Everything an open changed, as ``GroupRatchetStore/applyOpen(_:in:from:se:n:)`` writes it, in this order: the chain
/// upserted, the keys it banked inserted where none is stored, then the stored key it spent deleted by its full key
/// (`OpenDelta` and `GroupRatchetRepository.applyOpen`, knit-next `GroupRatchetRepository.kt:74-98`, whose delete takes
/// every mint's key at the index: knit-next #177).
public struct GroupOpenDelta: Sendable, Equatable {
    /// The chain to upsert, or `nil` when only a stored key was spent.
    public var recvChain: GroupRecvChainRecord?
    /// Keys for the indices the frame skipped.
    public var skippedInserts: [GroupSkippedKeyRecord]
    /// The mint of the stored key that opened the frame at the header's `(se, n)`, or `nil`: that key alone goes.
    public var consumedSkippedMintedAt: Int64?

    /// An open's changes.
    public init(
        recvChain: GroupRecvChainRecord?, skippedInserts: [GroupSkippedKeyRecord] = [], consumedSkippedMintedAt: Int64? = nil
    ) {
        self.recvChain = recvChain
        self.skippedInserts = skippedInserts
        self.consumedSkippedMintedAt = consumedSkippedMintedAt
    }
}

/// Everything a ``GroupRatchetStore`` holds for one group, for diagnostics and the tests' state digests (A9's
/// `groupState`, and knit-next's `MemoryGroupRatchetStore`'s `allSendChains`, `allRecvChains`, `allSkipped` and
/// `outboxOf` on the A9 branch): every send chain, retired ones included, the newest epoch first; each sender's receive
/// chains by epoch then mint, and its skipped keys by epoch, mint and index; and the outbox in member order.
public struct GroupRatchetHoldings: Sendable, Equatable {
    /// Our send chains, the newest epoch first.
    public var sendChains: [GroupSendChainRecord]
    /// Each sender's receive chains, by epoch then mint. A sender with none has no entry.
    public var recvChains: [NodeId: [GroupRecvChainRecord]]
    /// Each sender's skipped keys, by epoch, mint and index. A sender with none has no entry.
    public var skippedKeys: [NodeId: [GroupSkippedKeyRecord]]
    /// The outbox, in member order.
    public var outbox: [GroupKeySendRecord]

    /// What one group's rows hold.
    public init(
        sendChains: [GroupSendChainRecord],
        recvChains: [NodeId: [GroupRecvChainRecord]],
        skippedKeys: [NodeId: [GroupSkippedKeyRecord]],
        outbox: [GroupKeySendRecord]
    ) {
        self.sendChains = sendChains
        self.recvChains = recvChains
        self.skippedKeys = skippedKeys
        self.outbox = outbox
    }

    /// Nothing held.
    public static let empty = Self(sendChains: [], recvChains: [:], skippedKeys: [:], outbox: [])
}
