public import KnitWire

/// The group form's state machine, knit-next's sender-key ratchet (`GroupRatchetEngine` in
/// `mesh/crypto/ratchet/GroupRatchetEngine.kt`, at `cbf2a487`; companion change A9 adds only the IV source, `newIv`).
/// Pure, as the Kotlin is: a chain comes in as a value, and every change goes out as a ``SealResult``, an
/// ``AdoptOutcome`` or an ``OpenOutcome`` the caller persists in one store unit with what the frame carries (ADR
/// 2026-10.5sk9). No store, no clock and no policy memory of its own, and no key-request state either, which is the
/// session layer's (`GroupRatchetSessions` in KnitMesh). A seed and a frame's IV come from injected sources that default
/// to the system's generator, never the mesh's injected one (`crypto.md`). Only `GroupRatchetSessions` calls it, and
/// nothing in the mesh calls that before phase P6a2, so the group form stays dark behind `MeshConfiguration.ratchet`.
///
/// Much smaller than ``RatchetEngine``, deliberately (`:12-24`): no sessions, no DH and no races. Each member's chain is
/// authored by that member alone; trust, freshness and healing are the pairwise DM session's, which carries the seeds.
/// What remains:
/// - **Epochs derive independently** from their seed, which binds the group, the sender and the epoch
///   (``GroupRatchetCrypto/deriveEpoch(seed:groupId:senderId:epoch:)``): a sender's epochs open in any order, and an
///   epoch lost whole loses only itself.
/// - **Eras are mint-stamped.** A sender that lost its state mints from epoch 1 again under a newer `mintedAt`. Receivers
///   key their rows by `(epoch, mintedAt)`, adopt the newer mint and let the older one drain, so a receiver that adopted
///   the old era first opens both eras' re-serves: ``open(_:header:nonce:ct:aad:now:)`` tries the chains newest mint
///   first, and the AEAD decides. One that meets the re-mint's seed first refuses the old seed as stale and loses the old
///   era's unopened frames, as Kotlin's does (A9's `groupRestoreRemint`).
/// - **A retired chain keeps its number** (knit-next `0f519d71`, knit-next ADR 2026-10.xgwj): a departure's or a
///   rejoin's rekey, a leave and a delete leave our newest epoch key-less at the cap (``SendChain/retired()``), so the
///   next mint numbers past it and no receiver meets two mints of one epoch from a sender that kept its state. Only a
///   wipe restarts the numbering, which is A9's `groupRestoreRemint`.
/// - **A receive chain never needs its seed again:** adoption keeps the derived chain alone
///   (``adoptSeed(existing:groupId:senderId:epoch:seed:mintedAt:now:)``).
public struct GroupRatchetEngine: Sendable {
    /// Messages per epoch, within the custody quotas a group's and a sender's backlog fits in (`MAX_EPOCH_MESSAGES`,
    /// `:339`); `n` stays below it.
    public static let maxEpochMessages = 200
    /// An epoch's age cap, the custody TTL (`MAX_EPOCH_AGE_MS`, `:342`): no frame still deliverable is older.
    public static let maxEpochAgeMilliseconds: Int64 = 86_400_000
    /// The highest epoch number a header may name (`MAX_EPOCH_NUMBER`, `:349`), the DM engine's ceiling: an absurd
    /// number is `BAD_HEADER`, never a missing key that drives a key request.
    public static let maxEpochNumber = 1 << 24

    private let seed: @Sendable () -> [UInt8]
    private let iv: @Sendable () -> [UInt8]

    /// An engine whose epoch seeds come from `seed` and whose frames' AES-GCM IVs come from `iv` (`GroupRatchetEngine(newSeed,
    /// newIv)`, `:26-28` and A9's `newIv`). Leave both at the system's generator: only a test or a vector replay passes
    /// others.
    @preconcurrency
    public init(
        seed: @escaping @Sendable () -> [UInt8] = { GroupRatchetCrypto.newSeed() },
        iv: @escaping @Sendable () -> [UInt8] = { RatchetCrypto.randomNonce() }
    ) {
        self.seed = seed
        self.iv = iv
    }

    /// Mints our next send epoch for `groupId` (`mint`, `:147-166`): a fresh seed, its chain at index 0, numbered one past
    /// `previousEpoch` and stamped `now`, our clock. `previousEpoch` is the newest send chain's number, a retired one's
    /// included, so a forced rekey numbers past it; 0 only when no chain is held, after a wipe or before the first mint.
    public func mint(groupId: String, selfId: NodeId, previousEpoch: Int, now: Int64) -> SendChain {
        let drawn = seed()
        let epoch = previousEpoch + 1
        let keys = GroupRatchetCrypto.deriveEpoch(seed: drawn, groupId: groupId, senderId: selfId.string, epoch: epoch)
        return SendChain(epoch: epoch, seed: drawn, chainKey: keys.chainKey, count: 0, mintedAt: now)
    }

    /// Whether the next seal must mint a fresh epoch (`needsNewEpoch`, `:168-178`): no chain at all, which is a wipe and
    /// the one case that restarts the numbering at 1; a chain at the cap, which a retired chain always is; or a chain a
    /// day old. The age reads our own clock against our own stamp, wrapping as Kotlin's `Long` does.
    public static func needsNewEpoch(_ chain: SendChain?, now: Int64) -> Bool {
        guard let chain else {
            return true
        }
        return chain.count >= maxEpochMessages || now &- chain.mintedAt >= maxEpochAgeMilliseconds
    }

    /// Seals one frame under `chain` (`seal`, `:180-195`): the message key at the chain's count, a fresh IV, and the
    /// chain advanced by one. Persist the advanced chain before the frame leaves, or the next seal reuses its key.
    ///
    /// Answers `nil` for a chain at the cap, a retired one included: mint first (``needsNewEpoch(_:now:)``). Throws only
    /// on an IV that is not 12 bytes, which only a test's source gives: this port's guard refuses it (`RatchetCrypto.seal`),
    /// where the JVM's GCM seals under any IV that is not empty. Nothing is committed then.
    public func seal(_ chain: SendChain, plaintext: [UInt8], aad: [UInt8]) throws(RatchetCryptoError) -> SealResult? {
        guard chain.count < Self.maxEpochMessages else {
            return nil
        }
        let nonce = iv()
        let ct = try RatchetCrypto.seal(plaintext, key: GroupRatchetCrypto.messageKey(chain.chainKey), nonce: nonce, aad: aad)
        var advanced = chain
        advanced.chainKey = GroupRatchetCrypto.nextChainKey(chain.chainKey)
        advanced.count += 1
        return SealResult(header: GroupRatchetHeader(se: chain.epoch, n: chain.count), nonce: nonce, ct: ct, chain: advanced)
    }

    /// Decides one inbound seed for `(groupId, senderId, epoch)` against `existing`, the newest-mint chain held for that
    /// sender and epoch, if any (`adoptSeed`, `:197-229`). The comparison is on `mintedAt` alone, the sender's own clock
    /// compared only with itself: an equal stamp is a custody re-serve, recognized and never rewinding the chain; an older
    /// one is stale; anything else adopts, deriving the chain and keeping no seed. The caller holds the roster gate and
    /// the adoption floor (four a day per group and sender), and applies both before it stores an adoption.
    public func adoptSeed( // swiftlint:disable:this function_parameter_count - Kotlin's signature (`:204-212`), as the facade calls it
        existing: RecvChain?,
        groupId: String,
        senderId: NodeId,
        epoch: Int,
        seed: [UInt8],
        mintedAt: Int64,
        now: Int64
    ) -> AdoptOutcome {
        if let existing {
            if existing.mintedAt == mintedAt {
                return .alreadyKnown
            }
            if existing.mintedAt > mintedAt {
                return .stale
            }
        }
        let keys = GroupRatchetCrypto.deriveEpoch(seed: seed, groupId: groupId, senderId: senderId.string, epoch: epoch)
        return .adopt(RecvChain(epoch: epoch, mintedAt: mintedAt, chainKey: keys.chainKey, next: 0, lastUsedAt: now))
    }

    /// Opens one group frame (`open`, `:231-334`): a header outside the bounds is `BAD_HEADER`; then a stored skipped key
    /// for `(se, n)`, any mint's, whose hit spends that key alone and touches no chain; then each chain for `se`, newest
    /// mint first, filling any index hole with skipped keys, while the AEAD decides which mint the frame is from. Nothing
    /// changes on a failure, and nothing throws: every failure is delivery-local.
    ///
    /// The verdict when nothing opens: `NO_KEY` with no chain and no key held, so the seed has not arrived; `DUPLICATE`
    /// when some chain had spent the index and none failed its AEAD, a benign re-serve; `AEAD_FAIL` otherwise, another
    /// mint's frame or a corrupt one. Kotlin trusts its caller to pass only the header's chains and keys; this reads only
    /// those whose `se` and `n` are the header's, and orders the chains by mint itself.
    ///
    /// Two places differ from Kotlin's open. The delta names the mint of the key it spent, so the store spends that key by
    /// its full key, where Kotlin's names the index and its store deletes every mint's key there: a receiver holding both
    /// eras of a wiped sender's epoch then lost one frame per index they share (knit-next #177). And a carried nonce that
    /// is not 12 bytes fails the AEAD here (`RatchetCrypto.open`), where the JVM's GCM takes any IV that is not empty and
    /// opens a frame sealed under it. No Kotlin sender seals under another length (`AesGcm.randomIv`), and a 12-byte
    /// frame's nonce cut or lengthened fails both.
    public func open( // swiftlint:disable:this function_parameter_count - Kotlin's signature (`:237-244`), as the facade calls it
        _ context: OpenContext,
        header: GroupRatchetHeader,
        nonce: [UInt8],
        ct: [UInt8],
        aad: [UInt8],
        now: Int64
    ) -> OpenOutcome {
        guard (1...Self.maxEpochNumber).contains(header.se), (0..<Self.maxEpochMessages).contains(header.n) else {
            return .failed(.badHeader)
        }
        let keys = context.skippedKeys.filter { $0.epoch == header.se && $0.index == header.n }
        for key in keys {
            if let plaintext = RatchetCrypto.open(ct, key: key.messageKey, nonce: nonce, aad: aad) {
                let delta = OpenDelta(recvChain: nil, skippedInserts: [], consumedSkippedMintedAt: key.mintedAt)
                return .opened(OpenOutcome.Opened(plaintext: plaintext, delta: delta))
            }
        }
        let chains = context.chains.filter { $0.epoch == header.se }.sorted { $0.mintedAt > $1.mintedAt }
        var consumed = false
        var aeadFailed = false
        for chain in chains {
            guard header.n >= chain.next else {
                // Spent on this chain and no stored key matched: a re-serve, unless an older mint below opens it.
                consumed = true
                continue
            }
            if let opened = openOnChain(chain, header: header, nonce: nonce, ct: ct, aad: aad, now: now) {
                return .opened(opened)
            }
            aeadFailed = true
        }
        if chains.isEmpty, keys.isEmpty {
            return .failed(.noKey)
        }
        return .failed(consumed && !aeadFailed ? .duplicate : .aeadFail)
    }

    /// Advances `chain` to the header's index and opens the frame there (`openOnChain`, `:297-334`): the keys it passes
    /// are banked as skipped keys of the chain's mint, created now, and the chain moves past the index, last used now.
    private func openOnChain( // swiftlint:disable:this function_parameter_count - Kotlin's (`:298-305`), with the frame open
        _ chain: RecvChain,
        header: GroupRatchetHeader,
        nonce: [UInt8],
        ct: [UInt8],
        aad: [UInt8],
        now: Int64
    ) -> OpenOutcome.Opened? {
        var chainKey = chain.chainKey
        var skipped: [SkippedKey] = []
        for index in stride(from: chain.next, to: header.n, by: 1) {
            let messageKey = GroupRatchetCrypto.messageKey(chainKey)
            skipped.append(SkippedKey(epoch: header.se, mintedAt: chain.mintedAt, index: index, messageKey: messageKey, createdAt: now))
            chainKey = GroupRatchetCrypto.nextChainKey(chainKey)
        }
        guard let plaintext = RatchetCrypto.open(ct, key: GroupRatchetCrypto.messageKey(chainKey), nonce: nonce, aad: aad) else {
            return nil
        }
        var advanced = chain
        advanced.chainKey = GroupRatchetCrypto.nextChainKey(chainKey)
        advanced.next = header.n + 1
        advanced.lastUsedAt = now
        return OpenOutcome.Opened(
            plaintext: plaintext, delta: OpenDelta(recvChain: advanced, skippedInserts: skipped, consumedSkippedMintedAt: nil))
    }
}
