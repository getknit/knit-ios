/// One of our own epoch pairs for a peer, which the peer DHes new epochs against (`RatchetLocalEpochEntity`, knit-next
/// `data/ratchet/RatchetEntities.kt:40-56`). Deleting these rows is the forward-secrecy guarantee
/// (``RatchetRetention/retiredLocalEpochs(_:highestPeAcked:now:)``). Keyed by `(peer, epoch)`: a number minted again,
/// after our reset restarted the numbering, replaces the dead era's key (knit-next ADR 027).
public struct RatchetLocalEpochRecord: Sendable, Equatable {
    /// The epoch's number, a peer's `pe`.
    public var epoch: Int
    /// The private scalar. A secret.
    public var privateKey: [UInt8]
    /// The public value.
    public var publicKey: [UInt8]
    /// When it was minted, on our clock: retention orders by it, never by number.
    public var createdAt: Int64

    /// An epoch pair.
    public init(epoch: Int, privateKey: [UInt8], publicKey: [UInt8], createdAt: Int64) {
        self.epoch = epoch
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.createdAt = createdAt
    }
}

/// One peer epoch's receive chain (`RatchetRecvEpochEntity`, `RatchetEntities.kt:58-78`), keyed by `(peer, epoch,
/// rootTag)`: a peer's reset restarts its numbering, so two eras can hold one number, and only the matching root's
/// candidate reads a row (knit-next ADR 2026-10.gcrd).
public struct RatchetRecvEpochRecord: Sendable, Equatable {
    /// The peer's epoch number.
    public var epoch: Int
    /// The local tag of the root that derived it.
    public var rootTag: Int64
    /// The chain key at ``next``. A secret.
    public var chainKey: [UInt8]
    /// The next index the chain has not spent.
    public var next: Int
    /// When it last opened a frame, on our clock.
    public var lastUsedAt: Int64

    /// A receive chain.
    public init(epoch: Int, rootTag: Int64, chainKey: [UInt8], next: Int, lastUsedAt: Int64) {
        self.epoch = epoch
        self.rootTag = rootTag
        self.chainKey = chainKey
        self.next = next
        self.lastUsedAt = lastUsedAt
    }
}

/// A stored message key for a frame that has not arrived yet (`RatchetSkippedKeyEntity`, `RatchetEntities.kt:80-96`),
/// keyed by `(peer, epoch, index, rootTag)`, inserted only where none is stored and spent by its own root's tag.
public struct RatchetSkippedKeyRecord: Sendable, Equatable {
    /// The peer's epoch number.
    public var epoch: Int
    /// The local tag of the root that derived it.
    public var rootTag: Int64
    /// The chain index it opens, Kotlin's `idx`.
    public var index: Int
    /// The message key. A secret.
    public var messageKey: [UInt8]
    /// When it was derived, on our clock: skipped keys age from creation.
    public var createdAt: Int64

    /// A skipped key.
    public init(epoch: Int, rootTag: Int64, index: Int, messageKey: [UInt8], createdAt: Int64) {
        self.epoch = epoch
        self.rootTag = rootTag
        self.index = index
        self.messageKey = messageKey
        self.createdAt = createdAt
    }
}

/// Everything an open changed, as ``RatchetStore/applyOpen(_:from:se:n:)`` writes it, in this order: the purge, the
/// session, the receive chain, the skipped keys inserted where none is stored, then the spent key deleted by its own
/// root's tag (`RatchetEngine.OpenDelta` and `RatchetRepository.applyOpen`, knit-next `RatchetRepository.kt:54-92`).
public struct RatchetOpenDelta: Sendable, Equatable {
    /// The session after the open.
    public var session: RatchetSessionRecord
    /// The receive chain to upsert, or `nil` when only a skipped key was spent and its chain is gone.
    public var recvEpoch: RatchetRecvEpochRecord?
    /// Keys for the indices the frame skipped.
    public var skippedInserts: [RatchetSkippedKeyRecord]
    /// The tag of the skipped key the frame spent at the header's `(se, n)`, or `nil`.
    public var consumedSkippedTag: Int64?
    /// Whether a root change was adopted: every receive chain and skipped key held for the peer goes first.
    public var purgePeerRecvState: Bool

    /// An open's changes.
    public init(
        session: RatchetSessionRecord,
        recvEpoch: RatchetRecvEpochRecord?,
        skippedInserts: [RatchetSkippedKeyRecord] = [],
        consumedSkippedTag: Int64? = nil,
        purgePeerRecvState: Bool = false
    ) {
        self.session = session
        self.recvEpoch = recvEpoch
        self.skippedInserts = skippedInserts
        self.consumedSkippedTag = consumedSkippedTag
        self.purgePeerRecvState = purgePeerRecvState
    }
}

/// Everything a ``RatchetStore`` holds for one peer, for diagnostics and the tests' state digests (the debug bridge's
/// `debugLocalEpochs`, and `MemoryRatchetStore`'s `sessionOf`, `localEpochsOf`, `recvOf` and `skippedOf` in knit-next's
/// `RatchetTranscript.kt:216-231`): our epochs the most recently minted first, the receive chains by epoch then root
/// tag, and the skipped keys by epoch, root tag and index.
public struct RatchetPeerRecords: Sendable, Equatable {
    /// The session, or `nil` for none.
    public var session: RatchetSessionRecord?
    /// Our epochs for the peer, the most recently minted first (`createdAt` then epoch, both descending).
    public var localEpochs: [RatchetLocalEpochRecord]
    /// Every receive chain held for the peer, whatever root derived it.
    public var recvEpochs: [RatchetRecvEpochRecord]
    /// Every skipped key held for the peer, whatever root derived it.
    public var skippedKeys: [RatchetSkippedKeyRecord]

    /// What one peer's rows hold.
    public init(
        session: RatchetSessionRecord?,
        localEpochs: [RatchetLocalEpochRecord],
        recvEpochs: [RatchetRecvEpochRecord],
        skippedKeys: [RatchetSkippedKeyRecord]
    ) {
        self.session = session
        self.localEpochs = localEpochs
        self.recvEpochs = recvEpochs
        self.skippedKeys = skippedKeys
    }
}
