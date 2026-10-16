public import KnitWire

extension RatchetEngine {
    /// One peer's session, as its row will hold it (`SessionState`, `RatchetEngine.kt:41-65`). Field names are
    /// Kotlin's, so a column, a state digest and a vector read the same. Fields are `var` where Kotlin has `copy`.
    ///
    /// Left out: Kotlin's `sendEpochExport`, the epoch's export half, which only knit-next's spool reads and which
    /// production never reads back. The spool's exports are not in this port (ADR 2026-10.5sk9).
    public struct SessionState: Sendable, Equatable {
        /// The peer.
        public var peerId: NodeId
        /// Whether the peer has shown it holds this root: a responder's session is confirmed from the start, and an
        /// initiator's once the peer seals against an epoch of ours under it. Until then every frame carries the init.
        public var confirmed: Bool
        /// Whether we sent the init this root came from. It sets each direction's epoch label.
        public var weAreInitiator: Bool
        /// The session root, which never changes for the session's life. A secret.
        public var root: [UInt8]
        /// The other root a resolution kept: the one a replacement, a reset or a race's loss left, or the loser's root a
        /// race's winner reads. It opens frames still on their way, read-only, until ``prevRootExpiresAt``.
        public var prevRoot: [UInt8]?
        /// Our role under ``prevRoot``.
        public var prevRootWeAreInitiator: Bool
        /// When ``prevRoot`` stops opening frames, on our clock.
        public var prevRootExpiresAt: Int64
        /// When the session started: our clock exactly when we initiated, else the peer's `init.at` (Kotlin's
        /// `establishedAtIsOurOwnClockExactlyWhenWeAreTheInitiator`). The session layer's era gate relies on that split.
        public var establishedAt: Int64
        /// Our pending init's ephemeral, sent until the session confirms.
        public var initEphPub: [UInt8]?
        /// The id of the peer's prekey our init names.
        public var initPkid: Int
        /// The peer init we last resolved (answered, adopted or drained): known by its ephemeral, never its stamp, so a
        /// re-served init is inert.
        public var peerInitEphPub: [UInt8]?
        /// The peer's newest epoch we DH our next epoch against; `nil` while the peer has contributed none.
        public var peerBasePub: [UInt8]?
        /// That epoch's number, 0 for none.
        public var peerBaseEpoch: Int
        /// Our send epoch's number, 0 before the first.
        public var sendEpoch: Int
        /// Our send epoch's public key, the header's `ek`.
        public var sendEpochPub: [UInt8]?
        /// The chain key the next seal spends. A secret.
        public var sendChainKey: [UInt8]?
        /// How many frames the send epoch has sealed, the next one's `n`.
        public var sendCount: Int
        /// When the send epoch started, on our clock.
        public var sendEpochStartedAt: Int64
        /// The peer epoch the send epoch is based on, the header's `pe`: 0 for the peer's prekey.
        public var sendEpochBaseEpoch: Int
        /// The highest of our epochs the peer has sealed against.
        public var highestPeAcked: Int
        /// When we last sealed a reset to this peer, on our clock; the session layer's.
        public var lastResetSentAt: Int64

        /// A session, every optional field defaulting as Kotlin's do.
        public init(
            peerId: NodeId,
            confirmed: Bool,
            weAreInitiator: Bool,
            root: [UInt8],
            prevRoot: [UInt8]? = nil,
            prevRootWeAreInitiator: Bool = false,
            prevRootExpiresAt: Int64 = 0,
            establishedAt: Int64,
            initEphPub: [UInt8]? = nil,
            initPkid: Int = 0,
            peerInitEphPub: [UInt8]? = nil,
            peerBasePub: [UInt8]? = nil,
            peerBaseEpoch: Int = 0,
            sendEpoch: Int = 0,
            sendEpochPub: [UInt8]? = nil,
            sendChainKey: [UInt8]? = nil,
            sendCount: Int = 0,
            sendEpochStartedAt: Int64 = 0,
            sendEpochBaseEpoch: Int = 0,
            highestPeAcked: Int = 0,
            lastResetSentAt: Int64 = 0
        ) {
            self.peerId = peerId
            self.confirmed = confirmed
            self.weAreInitiator = weAreInitiator
            self.root = root
            self.prevRoot = prevRoot
            self.prevRootWeAreInitiator = prevRootWeAreInitiator
            self.prevRootExpiresAt = prevRootExpiresAt
            self.establishedAt = establishedAt
            self.initEphPub = initEphPub
            self.initPkid = initPkid
            self.peerInitEphPub = peerInitEphPub
            self.peerBasePub = peerBasePub
            self.peerBaseEpoch = peerBaseEpoch
            self.sendEpoch = sendEpoch
            self.sendEpochPub = sendEpochPub
            self.sendChainKey = sendChainKey
            self.sendCount = sendCount
            self.sendEpochStartedAt = sendEpochStartedAt
            self.sendEpochBaseEpoch = sendEpochBaseEpoch
            self.highestPeAcked = highestPeAcked
            self.lastResetSentAt = lastResetSentAt
        }
    }

    /// One of our own epoch pairs, which a peer DHes against (`LocalEpoch`, `:68-73`). A number minted again, after our
    /// reset restarted the numbering, replaces the dead era's key (knit-next ADR 027).
    public struct LocalEpoch: Sendable, Equatable {
        /// The epoch's number, a peer's `pe`.
        public let epoch: Int
        /// The private scalar. A secret.
        public let privateKey: [UInt8]
        /// The public value, the header's `ek` while it sends.
        public let publicKey: [UInt8]
        /// When it was minted, on our clock: retention orders by it, never by number.
        public let createdAt: Int64

        /// An epoch pair.
        public init(epoch: Int, privateKey: [UInt8], publicKey: [UInt8], createdAt: Int64) {
            self.epoch = epoch
            self.privateKey = privateKey
            self.publicKey = publicKey
            self.createdAt = createdAt
        }
    }

    /// One peer epoch's receive chain (`RecvEpoch`, `:79-85`), tagged with the root that derived it: only that root's
    /// candidate reads it (knit-next ADR 2026-10.gcrd).
    public struct RecvEpoch: Sendable, Equatable {
        /// The peer's epoch number.
        public var epoch: Int
        /// ``RatchetCrypto/rootTag(_:)`` of the root it was derived under.
        public var rootTag: Int64
        /// The chain key at ``next``. A secret.
        public var chainKey: [UInt8]
        /// The next index the chain has not spent; an index below it is consumed under this root.
        public var next: Int
        /// When it last opened a frame, on our clock: retention drops a chain unused for 48 h.
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

    /// A stored message key for a frame that has not arrived yet (`SkippedKey`, `:88-94`), tagged like ``RecvEpoch``.
    /// Inserted only if absent, and spent by its own root's tag (`RatchetDao.kt:92-102`).
    public struct SkippedKey: Sendable, Equatable {
        /// The peer's epoch number.
        public let epoch: Int
        /// ``RatchetCrypto/rootTag(_:)`` of the root it was derived under.
        public let rootTag: Int64
        /// The chain index it opens, Kotlin's `idx`.
        public let index: Int
        /// The message key. A secret.
        public let messageKey: [UInt8]
        /// When it was derived, on our clock: skipped keys age from creation.
        public let createdAt: Int64

        /// A skipped key.
        public init(epoch: Int, rootTag: Int64, index: Int, messageKey: [UInt8], createdAt: Int64) {
            self.epoch = epoch
            self.rootTag = rootTag
            self.index = index
            self.messageKey = messageKey
            self.createdAt = createdAt
        }
    }

    /// A sealed frame (`SealResult`, `:120-126`): its header, its carried nonce (`nil` for v3, whose nonce derives),
    /// its ciphertext and tag, the advanced session, and the epoch pair it minted, if any. Persist the session and
    /// the pair before the frame leaves.
    public struct SealResult: Sendable {
        /// The ratchet header, `flags` 0: a reset's flag is the session layer's, written after sealing.
        public let header: RatchetHeader
        /// The 12-byte IV a v2 frame carries, or `nil` for v3, whose envelope carries an empty one.
        public let nonce: [UInt8]?
        /// The ciphertext followed by its tag.
        public let ct: [UInt8]
        /// The session with its chain advanced.
        public let session: SessionState
        /// The send epoch this seal started, if it started one.
        public let newLocalEpoch: LocalEpoch?
    }

    /// A session just initiated and its first send epoch (`Initiation`, `:206-209`).
    public struct Initiation: Sendable {
        /// The unconfirmed session.
        public let session: SessionState
        /// Its first send epoch, based on the peer's prekey.
        public let epoch: LocalEpoch
    }

    /// What ``RatchetEngine/open(_:header:nonce:ct:aad:now:)`` needs from storage (`OpenContext`, `:135-168`): the
    /// caller reads rows, the engine does the math.
    public struct OpenContext: Sendable {
        /// Our node id: the race tiebreak and the remnant guard compare it with the peer's, as ASCII.
        public var selfNodeId: NodeId
        /// The peer, the frame's verified sender.
        public var peerId: NodeId
        /// The session held with the peer, if any.
        public var session: SessionState?
        /// Every stored receive chain for the header's `se`, whatever root derived it; each candidate takes its own tag's.
        public var recvEpochs: [RecvEpoch]
        /// Every stored skipped key for the header's `(se, n)`, whatever root derived it.
        public var skippedKeys: [SkippedKey]
        /// Our local epoch's private key for the header's `pe`, when `pe ≥ 1` and we still hold it: looked up by number
        /// alone (`RatchetSessions.kt:134`).
        public var ownBasePrivateKey: [UInt8]?
        /// Our identity, whose X25519 half X3DH answers with.
        public var identity: IdentityKeys
        /// The peer's pinned bundle, whose X25519 half X3DH answers to.
        public var peerIdentity: PublicKeyBundle
        /// Our prekey the init names by `pkid`, while we keep it (``PrekeyRing/prekey(id:)``); `nil` with no init.
        public var prekeyForInit: SignedPrekey?
        /// Whether an init that would replace a resolved session may do so now. The session layer floors replacements
        /// per peer, an hour, or a minute for an init flagged `FLAG_RESET` (knit-next ADR 023); `false` leaves the init
        /// inert, and the frame is read under the roots already held.
        public var allowReplacement: Bool
        /// Whether the frame's header carries `FLAG_RESET`: the peer asking to start over. It exempts the init from the
        /// race-remnant guard and keeps it out of the read-only remnant candidate, since a reset is minted fresh and is
        /// adopted or refused, never read without adoption (knit-next ADR 024).
        public var resetRequested: Bool
        /// Whether an init the held session has not resolved may move its era at all, by a race or a replacement. `false`
        /// only for a frame this port's own custody hands back at start (ADR 2026-10.5sk9, phase P5a), which is read
        /// under the roots already held: its first verdict came before the restart, and an era it would move to may be
        /// one the pair has since left. Kotlin replays nothing from its own custody, so it has no such open. With no
        /// session held, an init still establishes one.
        public var allowEraChange: Bool

        /// A context; replacement and era changes allowed and no reset requested unless said.
        public init(
            selfNodeId: NodeId,
            peerId: NodeId,
            session: SessionState?,
            recvEpochs: [RecvEpoch],
            skippedKeys: [SkippedKey],
            ownBasePrivateKey: [UInt8]?,
            identity: IdentityKeys,
            peerIdentity: PublicKeyBundle,
            prekeyForInit: SignedPrekey?,
            allowReplacement: Bool = true,
            resetRequested: Bool = false,
            allowEraChange: Bool = true
        ) {
            self.selfNodeId = selfNodeId
            self.peerId = peerId
            self.session = session
            self.recvEpochs = recvEpochs
            self.skippedKeys = skippedKeys
            self.ownBasePrivateKey = ownBasePrivateKey
            self.identity = identity
            self.peerIdentity = peerIdentity
            self.prekeyForInit = prekeyForInit
            self.allowReplacement = allowReplacement
            self.resetRequested = resetRequested
            self.allowEraChange = allowEraChange
        }
    }

    /// How an open ended (`OpenOutcome`, `:170-193`).
    public enum OpenOutcome: Sendable {
        /// The frame opened.
        case opened(Opened)
        /// It did not, and nothing changed.
        case failed(Failed)

        /// The plaintext and what to persist with the message row.
        public struct Opened: Sendable {
            /// The frame's plaintext: `MessageContent` for v2, `MessageContentV2` for v3.
            public let plaintext: [UInt8]
            /// The state change to commit in the message's store unit.
            public let delta: OpenDelta
        }

        /// The typed failures, which the session layer maps to drop reasons and the reset heuristic. Only `NO_SESSION`,
        /// `EPOCH_GONE` and `AEAD_FAIL` from an authenticated frame count toward a reset; `DUPLICATE` and `BAD_HEADER`
        /// never do (`RESET_TRIGGERING_DROPS`, `InboundPipeline.kt:3690-3704`).
        public enum Failed: Sendable, Equatable, Hashable {
            /// No session and no usable init: the peer assumes state we do not have.
            case noSession
            /// The header names one of our epochs or prekeys we no longer hold, or never did.
            case epochGone
            /// The index is already spent and no skipped key is held: a benign re-delivery.
            case duplicate
            /// A structurally invalid or out-of-bounds header.
            case badHeader
            /// Keys resolved and the AEAD refused: another era's root, a corrupt frame, or tampering.
            case aeadFail
        }
    }

    /// What an open changes (`OpenDelta`, `:195-204`), to apply in one store unit in this order: the purge, the session,
    /// the receive chain, the skipped keys inserted if absent, then the spent key deleted by its own root's tag
    /// (`applyOpen`, `RatchetRepository.kt:54-92`).
    public struct OpenDelta: Sendable {
        /// The session after the open: upsert.
        public let session: SessionState
        /// The receive chain to upsert, keyed by `(epoch, rootTag)`; `nil` when only a skipped key was spent and its
        /// chain is gone.
        public let recvEpoch: RecvEpoch?
        /// Keys for the indices the frame skipped, inserted only where none is stored.
        public let skippedInserts: [SkippedKey]
        /// The tag of the skipped key the frame spent at the header's `(se, n)`: only that root's key goes.
        public let consumedSkippedTag: Int64?
        /// Whether a root change was adopted: drop every receive chain and skipped key held for the peer first.
        public let purgePeerRecvState: Bool
    }
}
