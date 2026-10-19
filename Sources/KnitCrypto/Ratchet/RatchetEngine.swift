public import KnitWire

/// The DM ratchet's state machine (`RatchetEngine` in knit-next's `mesh/crypto/ratchet/RatchetEngine.kt`, at
/// `ac491f4c`; companion change A9 adds only the IV source, `newIv`). Pure, as the Kotlin is: a session comes in as a
/// value and every change goes out as a ``SealResult`` or an ``OpenOutcome`` the caller persists in one store unit
/// with the message row (ADR 2026-10.5sk9). No store, no clock and no randomness of its own: a key pair and a v2 IV
/// come from injected sources that default to the system's generator, never the mesh's injected one (`crypto.md`).
/// Nothing calls it yet: the session layer is P4c's, the mesh's wiring P5's, and the ratchet stays dark behind
/// `MeshConfiguration.ratchet`.
///
/// The invariants custody forces on it (`:5-33`):
/// - **Epochs derive independently** from a session root that never changes, so a peer's epochs open in any order
///   and an epoch lost whole loses only itself.
/// - **Our send numbering is monotone** across the roots a peer hands us (a race, a replacement), but not across our
///   own reset, which restarts at 1 (knit-next ADR 027). So a peer and an epoch number can name two eras at once.
/// - **Receive state carries the tag of the root that derived it** (``RecvEpoch/rootTag``, ``SkippedKey/rootTag``;
///   knit-next ADR 2026-10.gcrd), and each root candidate reads only its own: an old era's chain, drained under a
///   kept `prevRoot`, never decides a new-era frame of the same number (#135).
/// - **A receive chain never needs its root again**, which is what lets a superseded root drain for a while and
///   vanish.
/// - **Only a fresh derivation under the active root moves the session's era**: adopting the peer's epoch as our DH
///   base, raising `highestPeAcked` and confirming are claims about the era we hold now, and a frame read under any
///   other root, on a live chain or from a skipped key says nothing about it (knit-next ADR 2026-09.pz9g).
public struct RatchetEngine: Sendable {
    /// Messages per send epoch, the mesh's per-sender custody quota (`MAX_EPOCH_MESSAGES`, `:863`); `n` stays below it.
    public static let maxEpochMessages = 200
    /// The highest epoch number either side may name (`MAX_EPOCH_NUMBER`, `:871`): about 16 million turnarounds, so a
    /// header near `Int32.max` is refused before it can pin our DH base.
    public static let maxEpochNumber = 1 << 24
    /// How far past our anchor a peer's epoch may be and still become our DH base (`MAX_EPOCH_JUMP`, `:879`): custody
    /// holds 200 frames a sender for a day, so nothing we can still receive is more than a few hundred ahead.
    public static let maxEpochJump = 1024
    /// A send epoch's age cap, the custody TTL (`MAX_EPOCH_AGE_MS`, `:882`).
    public static let maxEpochAgeMilliseconds: Int64 = 86_400_000
    /// How long a superseded root keeps opening frames still on their way, twice the custody TTL (`PREV_ROOT_TTL_MS`,
    /// `:885`).
    public static let previousRootMilliseconds: Int64 = 172_800_000

    private let keyPair: @Sendable () -> RatchetCrypto.KeyPair
    private let iv: @Sendable () -> [UInt8]

    /// An engine whose X3DH ephemerals and epoch keys come from `keyPair` and whose v2 nonces come from `iv`
    /// (`RatchetEngine(newKeyPair, newIv)`, `:37-39` and A9's `:40-41`). Leave both at the system's generator: only a
    /// test or a vector replay passes others.
    @preconcurrency
    public init(
        keyPair: @escaping @Sendable () -> RatchetCrypto.KeyPair = { RatchetCrypto.generateKeyPair() },
        iv: @escaping @Sendable () -> [UInt8] = { RatchetCrypto.randomNonce() }
    ) {
        self.keyPair = keyPair
        self.iv = iv
    }

    /// Starts a session toward `peerId` by X3DH against its identity and its verified signed prekey, with our first
    /// send epoch based on that prekey (`initiate`, `:216-237`). The ephemeral's private half is spent on the root and
    /// never kept; its public half rides every frame as the init until the session confirms. `establishedAt` is our
    /// clock, `now`, which is what lets the session layer compare it with our own stamps alone.
    ///
    /// `peerPrekey` is also the session's DH base (``SessionState/peerBasePub``, at `peerBaseEpoch` 0) until the peer
    /// contributes an epoch of its own, which an open under the active root adopts over it (knit-next
    /// `RatchetEngine.kt:226-231`, `:250` at `4f3cd995`, #174). So every `pe = 0` epoch of the session is based on the
    /// prekey its init names, the one the receiver resolves by `init.pkid`: one based on a prekey the peer had rotated to
    /// since was unreadable there until a reset.
    ///
    /// Throws where Tink throws: a peer key X25519 refuses (a low-order or malformed identity key or prekey).
    public func initiate(
        peerId: NodeId,
        identity: IdentityKeys,
        peerIdentity: PublicKeyBundle,
        peerPrekey: PeerPrekey,
        now: Int64
    ) throws(RatchetCryptoError) -> Initiation {
        let ephemeral = keyPair()
        let root = try RatchetCrypto.x3dhInitiate(
            ikPriv: identity.agreementScalar,
            ekPriv: ephemeral.privateKey,
            peerIkPub: peerIdentity.agreementKey,
            peerSpkPub: peerPrekey.publicKey
        )
        let session = SessionState(
            peerId: peerId,
            confirmed: false,
            weAreInitiator: true,
            root: root,
            establishedAt: now,
            initEphPub: ephemeral.publicKey,
            initPkid: peerPrekey.id,
            peerBasePub: peerPrekey.publicKey
        )
        let started = try startSendEpoch(session, basePub: peerPrekey.publicKey, baseEpoch: 0, now: now)
        return Initiation(session: started.session, epoch: started.epoch)
    }

    /// Seals `plaintext` in the session's send epoch, moving first to a fresh epoch when one is due (`seal`,
    /// `:248-298`; knit-next `:258-319` at `4f3cd995`). The fresh epoch's DH base is ``SessionState/peerBasePub``: the
    /// peer's newest epoch once it has contributed one, else the prekey our init named, which `initiate` records.
    /// `peerPrekey` is only the fallback for a session that holds neither, one an older build initiated before the init's
    /// prekey was recorded (#174), and the session layer passes it through ``prekeyBase(_:peerPrekey:)``, which refuses a
    /// prekey the init does not name. `v3` seals the compact form (knit-next ADR 059): the header is bound into the AAD
    /// and the nonce derives from the message key and that AAD, so nothing random rides the wire; the chain and the header
    /// are v2's.
    /// The plaintext must already be laid out for the form, `MessageContentV2` for v3.
    ///
    /// Answers `nil` when a new epoch is due and there is no base: a chat then goes as v1, a ctl as its cleartext frame,
    /// and a seed waits. It also answers `nil`
    /// for a session missing its send chain or, unconfirmed, its init: unreachable by construction, where Kotlin's
    /// `checkNotNull` throws. Throws where Tink throws, on a base X25519 refuses, and on an IV that is not 12 bytes,
    /// which Java's GCM would seal under and no receiver would open (`InboundPipeline.kt:1746-1747`); only a test passes
    /// such a source. Nothing is committed when it throws.
    public func seal(
        _ state: SessionState,
        plaintext: [UInt8],
        aad: [UInt8],
        peerPrekey: PeerPrekey?,
        now: Int64,
        forceNewEpoch: Bool = false,
        v3: Bool = false
    ) throws(RatchetCryptoError) -> SealResult? {
        var session = state
        var newLocalEpoch: LocalEpoch?
        if forceNewEpoch || Self.needsNewEpoch(session, now: now) {
            guard let basePub = session.peerBasePub ?? peerPrekey?.publicKey else {
                return nil
            }
            let started = try startSendEpoch(session, basePub: basePub, baseEpoch: session.peerBaseEpoch, now: now)
            session = started.session
            newLocalEpoch = started.epoch
        }
        guard let chainKey = session.sendChainKey, let ek = session.sendEpochPub else {
            return nil
        }
        // The pending init rides every frame until the session confirms (`:270-279`).
        let initial: RatchetInit?
        if session.confirmed {
            initial = nil
        } else if let eph = session.initEphPub {
            initial = RatchetInit(eph: eph, pkid: session.initPkid, at: session.establishedAt)
        } else {
            return nil
        }
        let header = RatchetHeader(se: session.sendEpoch, ek: ek, pe: session.sendEpochBaseEpoch, n: session.sendCount, initial: initial)
        let messageKey = RatchetCrypto.messageKey(chainKey)
        let nonce: [UInt8]?
        let ct: [UInt8]
        if v3 {
            let boundAad = aad + RatchetCrypto.headerBindingBytes(header)
            nonce = nil
            ct = try RatchetCrypto.seal(
                plaintext,
                key: messageKey,
                nonce: RatchetCrypto.messageNonce(messageKey: messageKey, aad: boundAad),
                aad: boundAad
            )
        } else {
            let drawn = iv()
            nonce = drawn
            ct = try RatchetCrypto.seal(plaintext, key: messageKey, nonce: drawn, aad: aad)
        }
        session.sendChainKey = RatchetCrypto.nextChainKey(chainKey)
        session.sendCount += 1
        return SealResult(header: header, nonce: nonce, ct: ct, session: session, newLocalEpoch: newLocalEpoch)
    }

    /// Opens one inbound DM frame (`open`, `:324-335`). The ladder runs over the root candidates the session and the
    /// init resolve to (the active root first, a draining `prevRoot` second and, for an unanchored race winner, a late
    /// loser's root last), each reading only the receive state its own root derived: a stored skipped key, then the
    /// live chain of a known epoch, then, for a candidate holding neither, a fresh derivation. Every change rides the
    /// answer's ``OpenDelta``, and nothing changes on a failure.
    ///
    /// `nonce` is the carried v2 IV, or `nil` for v3, whose nonce derives from each candidate key. A carried nonce
    /// that is not 12 bytes is `BAD_HEADER` here, where Kotlin's pipeline refuses it before its engine
    /// (`InboundPipeline.kt:1025-1028`, `:1746-1747`): AES-GCM would only refuse it as `AEAD_FAIL`, which counts toward
    /// a reset. The pipeline's other shape rules (a v3 envelope carries an empty nonce, a DM form is never addressed to
    /// a group) are the caller's, before it calls this.
    ///
    /// Throws only where Tink throws out of Kotlin's engine: an X3DH respond over a key X25519 refuses, the init's
    /// ephemeral or the peer's identity key (`respond`, `:707-716`). The caller refuses that frame with nothing
    /// committed and counts nothing toward a reset, as `InboundPipeline`'s `runCatching` records `DECRYPT_FAILED`; it is
    /// never `AEAD_FAIL`. A bad `ek` is the typed `BAD_HEADER` instead (`:456-460`).
    public func open( // swiftlint:disable:this function_parameter_count - Kotlin's signature (`:324-331`), as P4c calls it
        _ context: OpenContext,
        header: RatchetHeader,
        nonce: [UInt8]?,
        ct: [UInt8],
        aad: [UInt8],
        now: Int64
    ) throws(RatchetCryptoError) -> OpenOutcome {
        guard Self.headerSane(header), nonce.map({ $0.count == RatchetCrypto.nonceByteCount }) ?? true else {
            return .failed(.badHeader)
        }
        guard let resolved = try resolveSession(context, header: header, now: now) else {
            return .failed(Self.sessionFailure(context, header: header))
        }
        var ladder = Ladder(context: context, resolved: resolved, header: header, nonce: nonce, ct: ct, aad: aad, now: now)
        return ladder.climb()
    }

    // MARK: Sending

    /// The prekey to hand ``seal(_:plaintext:aad:peerPrekey:now:forceNewEpoch:v3:)`` as its fallback base for `session`,
    /// from the peer's pinned `peerPrekey` (`prekeyBase`, knit-next `RatchetEngine.kt:320-333` at `4f3cd995`, #174): the
    /// one place the rule lives. A session we initiated that the peer has not answered bases every `pe = 0` epoch on the
    /// prekey its init names, the key the receiver resolves by `init.pkid`. ``initiate(peerId:identity:peerIdentity:peerPrekey:now:)``
    /// records it, so this matters only for a row an older build initiated with no base recorded: the peer's current
    /// prekey serves it only while it is still that one, and `nil` otherwise makes the next epoch boundary answer `nil`
    /// (a chat then goes v1, which the peer reads) rather than seal a frame the peer cannot open. Any other session is
    /// based on the peer's own epoch and never reads the prekey.
    public static func prekeyBase(_ session: SessionState, peerPrekey: PeerPrekey?) -> PeerPrekey? {
        guard let peerPrekey, !(session.weAreInitiator && !session.confirmed && peerPrekey.id != session.initPkid) else {
            return nil
        }
        return peerPrekey
    }

    /// Whether the next seal needs a fresh epoch (`needsNewEpoch`, `:300-311`): none yet, or a resolution that took the
    /// root away nulled the chain; the peer has contributed an epoch newer than our base (every turnaround is a fresh
    /// DH); the epoch is full; or it is a day old. The age reads our own clock against our own stamp, wrapping as
    /// Kotlin's `Long` does.
    static func needsNewEpoch(_ session: SessionState, now: Int64) -> Bool {
        if session.sendEpoch == 0 || session.sendChainKey == nil {
            return true
        }
        let healing = session.peerBaseEpoch > session.sendEpochBaseEpoch
        let full = session.sendCount >= maxEpochMessages
        let aged = now &- session.sendEpochStartedAt >= maxEpochAgeMilliseconds
        return healing || full || aged
    }

    /// A session with its send epoch just started, and that epoch's pair (`Started`, `:825-828`).
    private struct Started {
        let session: SessionState
        let epoch: LocalEpoch
    }

    /// A fresh send epoch (`startSendEpoch`, `:830-859`): a new pair, numbered one past the last, DHed against
    /// `basePub` under the session root, with the epoch sender's role as the direction.
    private func startSendEpoch(
        _ session: SessionState,
        basePub: [UInt8],
        baseEpoch: Int,
        now: Int64
    ) throws(RatchetCryptoError) -> Started {
        let pair = keyPair()
        let se = session.sendEpoch + 1
        let keys = RatchetCrypto.deriveEpoch(
            sessionRoot: session.root,
            dhShared: try RatchetCrypto.dh(pair.privateKey, basePub),
            senderIsInitiator: session.weAreInitiator,
            senderEpoch: se,
            baseEpoch: baseEpoch
        )
        var fresh = session
        fresh.sendEpoch = se
        fresh.sendEpochPub = pair.publicKey
        fresh.sendChainKey = keys.chainKey
        fresh.sendCount = 0
        fresh.sendEpochStartedAt = now
        fresh.sendEpochBaseEpoch = baseEpoch
        let epoch = LocalEpoch(epoch: se, privateKey: pair.privateKey, publicKey: pair.publicKey, createdAt: now)
        return Started(session: fresh, epoch: epoch)
    }

    // MARK: Opening

    /// Structural bounds only (`headerSane`, `:346-349`): nothing here reads the session, so what it refuses is
    /// `BAD_HEADER`, which never counts toward a reset. Both epoch numbers are bounded on both sides, since a negative or
    /// absurd `pe` used to reach a missing-key report (`EPOCH_GONE`), which does count. `pe = 0` names our signed prekey
    /// and is legal only while an init rides.
    static func headerSane(_ header: RatchetHeader) -> Bool {
        (1...maxEpochNumber).contains(header.se) && (0..<maxEpochMessages).contains(header.n)
            && header.ek.count == RatchetCrypto.keyByteCount && (0...maxEpochNumber).contains(header.pe)
            && (header.pe >= 1 || header.initial != nil)
    }

    /// Why a frame with no session to read it under fails (`sessionFailure`, `:494-502`): an init naming a prekey we no
    /// longer hold is `EPOCH_GONE`, anything else `NO_SESSION`, an init a session of ours anchored before included, which
    /// says only that the peer holds a session we lost, whichever prekey it names (ADR 2026-10.wcex).
    static func sessionFailure(_ context: OpenContext, header: RatchetHeader) -> OpenOutcome.Failed {
        header.initial != nil && context.prekeyForInit == nil && !context.initAnsweredBefore ? .epochGone : .noSession
    }
}
