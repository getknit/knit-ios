public import KnitWire

extension GroupRatchetEngine {
    /// One of our send epochs for a group, as its row will hold it (`SendChain`, `GroupRatchetEngine.kt:29-57`). The seed
    /// is kept while the epoch is current or draining, so it can be re-distributed; deleting the row is the sender's
    /// forward secrecy. The group is the caller's: the store keys the row by it.
    ///
    /// Left out: Kotlin's `export`, the epoch's export half, which only knit-next's spool reads (ADR 2026-10.5sk9), as the
    /// DM session keeps no `sendEpochExport`.
    public struct SendChain: Sendable, Equatable {
        /// The epoch's number, a frame's `se`.
        public var epoch: Int
        /// The epoch's seed, which the members derive the chain from: empty for a retired chain. A secret.
        public var seed: [UInt8]
        /// The chain key the next seal spends: empty for a retired chain. A secret.
        public var chainKey: [UInt8]
        /// How many frames the epoch has sealed, the next one's `n`: ``GroupRatchetEngine/maxEpochMessages`` for a retired
        /// chain.
        public var count: Int
        /// When it was minted, on our clock: receivers order a sender's mints of one epoch by it.
        public var mintedAt: Int64

        /// A send chain.
        public init(epoch: Int, seed: [UInt8], chainKey: [UInt8], count: Int, mintedAt: Int64) {
            self.epoch = epoch
            self.seed = seed
            self.chainKey = chainKey
            self.count = count
            self.mintedAt = mintedAt
        }

        /// Whether a forced rekey retired it (`isRetired`, `:41-46`): judged on the seed, never on the count, since a chain
        /// that reached the cap by sealing keeps its seed and is still re-served for the frames sealed under it.
        public var isRetired: Bool {
            seed.isEmpty
        }

        /// This chain with every key gone and the epoch spent (`retired`, `:48-56`): what a departure's or a rejoin's
        /// rekey, a leave or a delete leaves of our newest epoch, so the next mint numbers past it (knit-next ADR
        /// 2026-10.xgwj). Deleting the row instead restarted the numbering at 1 under a newer `mintedAt`, and a receiver
        /// that met the re-mint's seed first dropped the earlier one as stale and lost every frame sealed under it (#167).
        /// Its count at the cap makes ``GroupRatchetEngine/needsNewEpoch(_:now:)`` mint and ``GroupRatchetEngine/seal(_:plaintext:aad:)``
        /// refuse, and the empty seed keeps it out of every re-distribution.
        public func retired() -> Self {
            Self(epoch: epoch, seed: [], chainKey: [], count: GroupRatchetEngine.maxEpochMessages, mintedAt: mintedAt)
        }
    }

    /// One sender's receive chain for one epoch and mint (`RecvChain`, `:59-70`). The store keys it by group, sender,
    /// epoch and `mintedAt`, so a wiped sender's re-mint of a number sits beside the draining old era instead of
    /// overwriting it.
    public struct RecvChain: Sendable, Equatable {
        /// The sender's epoch number.
        public var epoch: Int
        /// When the sender minted it, on the sender's clock, compared only with the same sender's other mints of the epoch.
        public var mintedAt: Int64
        /// The chain key at ``next``. A secret.
        public var chainKey: [UInt8]
        /// The next index the chain has not spent; an index below it is consumed on this chain.
        public var next: Int
        /// When it last opened a frame, on our clock: retention drops a chain unused for 48 h.
        public var lastUsedAt: Int64

        /// A receive chain.
        public init(epoch: Int, mintedAt: Int64, chainKey: [UInt8], next: Int, lastUsedAt: Int64) {
            self.epoch = epoch
            self.mintedAt = mintedAt
            self.chainKey = chainKey
            self.next = next
            self.lastUsedAt = lastUsedAt
        }
    }

    /// A stored message key for a frame that has not arrived yet (`SkippedKey`, `:72-79`), of one sender's epoch and mint.
    /// Single-use, and spent by its full key: another mint's key at the same index belongs to that era's frame and stays,
    /// where Kotlin's store spends every mint's key at the index (knit-next #177).
    public struct SkippedKey: Sendable, Equatable {
        /// The sender's epoch number.
        public var epoch: Int
        /// The mint of the chain that banked it.
        public var mintedAt: Int64
        /// The chain index it opens, Kotlin's `idx`.
        public var index: Int
        /// The message key. A secret.
        public var messageKey: [UInt8]
        /// When it was banked, on our clock: skipped keys age from creation.
        public var createdAt: Int64

        /// A skipped key.
        public init(epoch: Int, mintedAt: Int64, index: Int, messageKey: [UInt8], createdAt: Int64) {
            self.epoch = epoch
            self.mintedAt = mintedAt
            self.index = index
            self.messageKey = messageKey
            self.createdAt = createdAt
        }
    }

    /// A sealed group frame (`SealResult`, `:87-92`): its header, the IV it carries, its ciphertext and tag, and the chain
    /// advanced past it. Persist the chain before the frame leaves.
    public struct SealResult: Sendable {
        /// The group header, `{se, n}`.
        public let header: GroupRatchetHeader
        /// The 12-byte IV the envelope carries.
        public let nonce: [UInt8]
        /// The ciphertext followed by its tag.
        public let ct: [UInt8]
        /// The chain with its key and count advanced.
        public let chain: SendChain
    }

    /// What ``GroupRatchetEngine/open(_:header:nonce:ct:aad:now:)`` needs from storage (`OpenContext`, `:94-100`): the
    /// caller reads the rows for the frame's group and sender, the engine does the math.
    public struct OpenContext: Sendable {
        /// The sender's receive chains for the header's `se`, every mint held: the live one and a draining older era.
        public var chains: [RecvChain]
        /// Every stored key for the header's `(se, n)`, any mint's.
        public var skippedKeys: [SkippedKey]

        /// A context.
        public init(chains: [RecvChain], skippedKeys: [SkippedKey]) {
            self.chains = chains
            self.skippedKeys = skippedKeys
        }
    }

    /// How an open ended (`OpenOutcome`, `:102-123`).
    public enum OpenOutcome: Sendable {
        /// The frame opened.
        case opened(Opened)
        /// It did not, and nothing changed.
        case failed(Failed)

        /// The plaintext and what to persist with the caller's rows.
        public struct Opened: Sendable {
            /// The frame's plaintext, a `MessageContent`.
            public let plaintext: [UInt8]
            /// The change to commit in the frame's store unit.
            public let delta: OpenDelta
        }

        /// The typed failures, which the caller maps to drop reasons and the key-request heuristic: `NO_KEY` and
        /// `AEAD_FAIL` may feed it, `DUPLICATE` and `BAD_HEADER` never do (`onGroupRatchetFailure`,
        /// `InboundPipeline.kt:1664-1684`).
        public enum Failed: Sendable, Equatable, Hashable {
            /// No adopted seed covers the frame's sender and epoch: its seed has not arrived, or was lost.
            case noKey
            /// The index is already spent and no stored key matched: a benign re-delivery.
            case duplicate
            /// A header outside the bounds.
            case badHeader
            /// Keys resolved and the AEAD refused: another mint's frame, or a corrupt one. The frame's signature was
            /// verified first, so never a third party's tampering.
            case aeadFail
        }
    }

    /// What an open changes (`OpenDelta`, `:125-131`), in one store unit: the chain advanced, the keys it banked, inserted
    /// where none is stored, and the stored key it spent.
    public struct OpenDelta: Sendable, Equatable {
        /// The chain to upsert; `nil` when only a stored key was spent.
        public let recvChain: RecvChain?
        /// Keys for the indices the frame skipped.
        public let skippedInserts: [SkippedKey]
        /// The mint of the stored key that opened the frame at the header's `(se, n)`, or `nil`: that key alone goes, by
        /// its full key, as the DM engine's `consumedSkippedTag` names its root's. Kotlin's names the index alone
        /// (`consumedSkippedIdx`), and its store deletes every mint's key there (knit-next #177).
        public let consumedSkippedMintedAt: Int64?
    }

    /// The verdict on one inbound seed (`AdoptOutcome`, `:133-145`).
    public enum AdoptOutcome: Sendable, Equatable {
        /// A new chain to store; older mints of the same epoch drain through the sweep.
        case adopt(RecvChain)
        /// The same `(epoch, mintedAt)` is already held: a custody re-serve, acknowledged again, its chain untouched.
        case alreadyKnown
        /// An older mint of an epoch held under a newer one: ignored, and not acknowledged.
        case stale
    }
}
