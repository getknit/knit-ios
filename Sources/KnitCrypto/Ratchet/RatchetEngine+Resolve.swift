public import KnitWire

extension RatchetEngine {
    /// The session a frame is read under and the roots it may open under, in order (`ResolvedSession`, `:351-356`).
    struct ResolvedSession {
        let session: SessionState
        /// The roots to try, each with the epoch sender's role under it.
        let candidates: [RootCandidate]
        /// Whether the resolution changed the root we hold: the receive state it leaves is purged, and the resolving
        /// frame reads nothing stored.
        let purge: Bool
        /// The flagged init the replacement floor alone refused, with the prekey it names, else `nil` (`flooredReset`,
        /// knit-next `RatchetEngine.kt:438-443` at `f018bc8ce`, its ADR 2026-11.sfms). The ladder still climbs; only when
        /// nothing opens does ``RatchetEngine/open(_:header:nonce:ct:aad:now:)`` derive its root, and answer
        /// `RESET_FLOORED` for a root the session does not hold.
        var flooredReset: FlooredReset?
    }

    /// A flagged init refused by the floor alone, and our prekey it names, which is what derives its root.
    struct FlooredReset {
        let initial: RatchetInit
        let prekey: SignedPrekey
    }

    /// One root a frame may open under (`RootCandidate`, `:363-370`). Only the ``active`` one, the root the resolved
    /// session holds as its own, may move the session's era; a draining `prevRoot`, a race's other root and a late
    /// race loser's are read-only, but for the one exception ``reclaimsAt`` names.
    struct RootCandidate {
        let root: [UInt8]
        /// The role, under this root, of whoever sealed the frame.
        let senderIsInitiator: Bool
        let active: Bool
        /// Set only on the draining `prevRoot` that is our own init, lost to a race, for a frame sealed after the init we
        /// lost to (``RatchetEngine/reclaimsPreviousRoot(_:_:)``): that init's own `establishedAt`. A frame that opens under
        /// this candidate, on any rung, moves the session back onto it (`reclaims`, knit-next `RatchetEngine.kt:455-459` at
        /// `f018bc8ce`, its ADR 2026-10.4mjm). Kotlin's candidate carries a flag and reads the stamp off the session; this
        /// one carries the stamp, so the reclaim unwraps nothing.
        let reclaimsAt: Int64?
        /// The tag the receive state this root derives carries.
        let tag: Int64

        /// A candidate that never reclaims.
        init(root: [UInt8], senderIsInitiator: Bool, active: Bool) {
            self.init(root: root, senderIsInitiator: senderIsInitiator, active: active, reclaimsAt: nil)
        }

        init(root: [UInt8], senderIsInitiator: Bool, active: Bool, reclaimsAt: Int64?) {
            self.root = root
            self.senderIsInitiator = senderIsInitiator
            self.active = active
            self.reclaimsAt = reclaimsAt
            tag = RatchetCrypto.rootTag(root)
        }
    }

    /// Applies the frame's init, if any, to the session it should be read under (`resolveSession`, `:512-595`); `nil`
    /// when nothing can read it (no session and no usable init). Throws where Kotlin's `respond` does.
    func resolveSession(_ context: OpenContext, header: RatchetHeader, now: Int64) throws(RatchetCryptoError) -> ResolvedSession? {
        guard let session = context.session else {
            // An init a session of ours anchored before a reinstall establishes nothing: the root it derives is one the
            // peer may have left, or is still answering under a session we lost (ADR 2026-10.wcex).
            guard !context.initAnsweredBefore else {
                return nil
            }
            return try establish(context, initial: header.initial)
        }
        var candidates = [RootCandidate(root: session.root, senderIsInitiator: !session.weAreInitiator, active: true)]
        if let prevRoot = session.prevRoot, session.prevRootExpiresAt > now {
            // Only this top-level candidate may reclaim; a race's resolution builds its own, which never do (`:647-650`).
            candidates.append(
                RootCandidate(
                    root: prevRoot,
                    senderIsInitiator: !session.prevRootWeAreInitiator,
                    active: false,
                    reclaimsAt: Self.reclaimsPreviousRoot(session, context)
                )
            )
        }
        guard let initial = header.initial else {
            return ResolvedSession(session: session, candidates: candidates, purge: false)
        }
        // An init we already resolved, riding a later unconfirmed frame or a custody re-serve: inert by its ephemeral,
        // never its stamp, or a re-served race loser's init would pass for a fresh replacement for its whole custody
        // TTL (`:540-543`).
        if session.peerInitEphPub == initial.eph {
            return ResolvedSession(session: session, candidates: candidates, purge: false)
        }
        // A frame that may not move the era, this port's start replay out of its own custody: an init the session has not
        // resolved neither races nor replaces it, and the frame is read under the roots held, the read-only remnant
        // included (``OpenContext/allowEraChange``). So too an init a session of ours anchored before a reinstall, which
        // the lost row can no longer tell apart from a new one (``OpenContext/initAnsweredBefore``, ADR 2026-10.wcex).
        guard context.allowEraChange, !context.initAnsweredBefore else {
            let remnants = try remnantCandidates(session, header: header, initial: initial, context: context)
            var held = ResolvedSession(session: session, candidates: candidates + remnants, purge: false)
            held.flooredReset = Self.flooredAtStart(session, initial: initial, context: context)
            return held
        }
        // Both sides initiated: we hold an unconfirmed session we started, and the peer's own init just arrived.
        // Decided by node id, never by `init.at`: two inits can carry one stamp, and both sides must pick one winner
        // (`:544-547`).
        if !session.confirmed, session.weAreInitiator {
            // A frame from before our reset, carrying the init that minted the root we replaced, is not a race (knit-next
            // ADR 2026-10.j67x's rule 2, `RatchetEngine.kt:660-667` at `f018bc8ce`). Our re-root dropped that era's anchor
            // with the rest of its state, so the peer's frames sealed as that root's unconfirmed initiator, each with its
            // init, come back from custody for a day: raced, a smaller-id peer would win, and we would adopt the root we
            // left while the peer may already be on ours. Read under the drained root, read-only, with no remnant and no
            // purge. A frame sealed since then is the peer still that root's unconfirmed initiator, never told our answer,
            // and races as before, or neither side would ever confirm.
            //
            // The guard above already read every init it holds back under the roots held, the draining `prevRoot`
            // included, so a start replay meets the same answer here. Nor can a rule-2 init be one answered before a
            // reinstall: the session layer's `isAnsweredBefore` says no for an init that derives the draining `prevRoot`.
            if context.predatesSession, try derivesPreviousRoot(context, session: session, initial: initial, now: now) {
                return ResolvedSession(session: session, candidates: candidates, purge: false)
            }
            return try resolveRace(context, session: session, initial: initial, now: now)
        }
        return try resolveReplacement(context, session: session, candidates: candidates, header: header, initial: initial, now: now)
    }

    /// A replacement (`:670-695` at `f018bc8ce`): the peer lost its state, or reset, and re-initiated. Only an init newer
    /// than the session we share, answerable with a prekey we hold, inside the caller's floor, and not the race remnant, in
    /// Kotlin's order. Refused is not unread: the remnant's frame is the loser's opening DM, still a real message (#83).
    private func resolveReplacement( // swiftlint:disable:this function_parameter_count - `resolveSession`'s state, handed on
        _ context: OpenContext,
        session: SessionState,
        candidates: [RootCandidate],
        header: RatchetHeader,
        initial: RatchetInit,
        now: Int64
    ) throws(RatchetCryptoError) -> ResolvedSession {
        let remnants = ResolvedSession(
            session: session,
            candidates: candidates + (try remnantCandidates(session, header: header, initial: initial, context: context)),
            purge: false
        )
        // A genuinely stale init, no newer than the session we share, changes nothing (`:671`).
        guard initial.at > session.establishedAt else {
            return remnants
        }
        guard context.allowReplacement, let prekey = context.prekeyForInit else {
            // A flagged init the floor alone refused is remembered for the verdict, and the ladder still climbs (`:672-676`,
            // knit-next ADR 2026-11.sfms, #251). Only past `resolveSession`'s guard, so an init answered before a reinstall is
            // never floored.
            var refused = remnants
            refused.flooredReset = context.resetRequested ? context.prekeyForInit.map { FlooredReset(initial: initial, prekey: $0) } : nil
            return refused
        }
        // The remnant guard refuses an init re-served from an era the peer has already left (`:677-694`): we won a race
        // without ever reading the loser's init, so nothing anchors it, and it can come back from custody newer than our
        // session for a whole TTL. Adopting it would defect to the losing root while the peer stays on ours, both
        // confirmed and diverged for good. `FLAG_RESET` is exempt (knit-next ADR 024): a reset is minted fresh, is the
        // only signal a peer that lost its state can send, and abandons the losing root on its side too.
        guard !Self.isRemnant(session, context) else {
            return remnants
        }
        return try replace(session, initial: initial, prekey: prekey, context: context, now: now)
    }

    /// The floored marker at this port's start replay out of its own custody (``OpenContext/allowEraChange`` `false`, ADR
    /// 2026-10.5sk9's P9b amendment), judged whatever the floor said, since it died with the process: a flagged init newer
    /// than the session we share, never answered before a reinstall, with our prekey held, under an era the peer opened.
    /// The verdict still asks that its root be one we never held, and the open still moves no era: the caller holds the
    /// frame, and opens it again as a first verdict. iOS ends a suspended Knit often, and the hold and the floor die with it,
    /// so without this a reset our floor refused would wait for the resetter's next, up to six hours. Kotlin replays nothing
    /// from its own custody, so it has no such rule.
    ///
    /// Only under an era the peer opened, where `establishedAt` is the peer's own `init.at` and the comparison reads one
    /// sender's stamps. Under an era we opened, a re-root or a reclaim of ours, our race state among them, it would compare
    /// the peer's clock with ours, and the root-generation drop that retired a hold taken before our re-root died with the
    /// process too: a peer clock ahead would let the re-open adopt a root the peer has left, a silent confirmed split. Such
    /// a reset waits for the resetter's next, as on Android.
    static func flooredAtStart(_ session: SessionState, initial: RatchetInit, context: OpenContext) -> FlooredReset? {
        guard !context.allowEraChange, !context.initAnsweredBefore, !session.weAreInitiator, context.resetRequested,
            initial.at > session.establishedAt, let prekey = context.prekeyForInit
        else {
            return nil
        }
        return FlooredReset(initial: initial, prekey: prekey)
    }

    /// A first frame to a peer we hold no session with: answer its init, confirmed from the start, the peer's stamp as
    /// `establishedAt` and its ephemeral as the anchor (`:519-533`).
    private func establish(_ context: OpenContext, initial: RatchetInit?) throws(RatchetCryptoError) -> ResolvedSession? {
        guard let initial, let prekey = context.prekeyForInit else {
            return nil
        }
        let root = try respond(context, prekey: prekey, initial: initial)
        let session = SessionState(
            peerId: context.peerId,
            confirmed: true,
            weAreInitiator: false,
            root: root,
            establishedAt: initial.at,
            peerInitEphPub: initial.eph
        )
        return ResolvedSession(
            session: session,
            candidates: [RootCandidate(root: root, senderIsInitiator: true, active: true)],
            purge: false
        )
    }

    /// The replacement (`:571-594`): the peer's numbering restarts at 1, so we answer its init as a responder, keep the
    /// old root draining as `prevRoot` for frames still on their way, and drop the chain and base of the era we leave.
    /// The rows of the old numbering go too, as hygiene: the root tag already keeps them off the new root's frames.
    private func replace(
        _ session: SessionState,
        initial: RatchetInit,
        prekey: SignedPrekey,
        context: OpenContext,
        now: Int64
    ) throws(RatchetCryptoError) -> ResolvedSession {
        let root = try respond(context, prekey: prekey, initial: initial)
        var replaced = session
        replaced.confirmed = true
        replaced.weAreInitiator = false
        replaced.root = root
        replaced.prevRoot = session.root
        replaced.prevRootWeAreInitiator = session.weAreInitiator
        replaced.prevRootExpiresAt = now &+ Self.previousRootMilliseconds
        // A root replaced, confirmed or not, is never ours to reclaim: its drain frames would swap us back into a dead era
        // (knit-next `RatchetEngine.kt:708-710` at `f018bc8ce`).
        replaced.prevRootOwnInitAt = nil
        replaced.establishedAt = initial.at
        replaced.peerInitEphPub = initial.eph
        replaced.peerBasePub = nil
        replaced.peerBaseEpoch = 0
        replaced.sendEpochPub = nil
        replaced.sendChainKey = nil
        return ResolvedSession(
            session: replaced,
            candidates: [RootCandidate(root: root, senderIsInitiator: true, active: true)],
            purge: true
        )
    }

    /// Whether `initial` derives the previous root `session` still drains at `now`, with the prekey `context` holds for it
    /// (`derivesPrevRoot`, knit-next `RatchetEngine.kt:642-656` at `4f3cd995`): the era that init founded is one this
    /// session left by a reset or a replacement of its own, not one a reinstall lost. The caller asks it before it reads
    /// an init as one a session of ours anchored before (``OpenContext/initAnsweredBefore``, ADR 2026-10.wcex), so such an
    /// init keeps this port's rules for a held era. The race branch pairs it with ``OpenContext/predatesSession`` to read,
    /// not race, a frame sealed before our session (`RatchetEngine.kt:667` at `f018bc8ce`, knit-next ADR 2026-10.j67x's
    /// rule 2). Throws where `respond` does.
    public func derivesPreviousRoot(
        _ context: OpenContext, session: SessionState, initial: RatchetInit, now: Int64
    ) throws(RatchetCryptoError) -> Bool {
        guard let previous = session.prevRoot, session.prevRootExpiresAt > now, let prekey = context.prekeyForInit else {
            return false
        }
        return try respond(context, prekey: prekey, initial: initial) == previous
    }

    /// The state the race-remnant guard reads (`isRemnantOf`, `:602-607`): a confirmed session we initiated with no
    /// peer init ever resolved (we won a race without reading the loser's init, or simply initiated), an init from the
    /// side that loses the node id tiebreak, and no `FLAG_RESET`. Node ids compare as ASCII, as Kotlin's strings do.
    static func isRemnant(_ session: SessionState, _ context: OpenContext) -> Bool {
        session.confirmed && session.weAreInitiator && session.peerInitEphPub == nil && !context.resetRequested
            && context.selfNodeId < session.peerId
    }

    /// The late race loser's root as a trailing read-only candidate (#83; `remnantCandidates`, `:629-637`). The loser
    /// adopts our root and answers under it, and those answers can overtake its own opening DM, sealed under the losing
    /// root and riding custody, so we confirm without ever reading its init. Offered only in the state ``isRemnant(_:_:)``
    /// names, for a frame sealed against our prekey (`pe = 0`), and never adopted or anchored: a resetter's follow-ups
    /// carry its reset's init without the flag, and anchoring one would turn the flagged reset itself into an inert
    /// re-serve. Re-serves of the DM end as `DUPLICATE` on the chain its first open stored.
    private func remnantCandidates(
        _ session: SessionState,
        header: RatchetHeader,
        initial: RatchetInit,
        context: OpenContext
    ) throws(RatchetCryptoError) -> [RootCandidate] {
        guard Self.isRemnant(session, context), header.pe == 0, let prekey = context.prekeyForInit else {
            return []
        }
        return [RootCandidate(root: try respond(context, prekey: prekey, initial: initial), senderIsInitiator: true, active: false)]
    }

    /// Both sides initiated (`resolveRace`, `:653-705`): the init whose initiator has the smaller node id wins, on both
    /// ends. The loser adopts the winner's root, keeps its own draining as `prevRoot` and purges the receive state of the
    /// era it leaves: two peers resetting each other race with restarted numbering, and the purge drops rows nothing will
    /// read (knit-next ADR 2026-10.gcrd). The winner keeps its root and its rows, reads the loser's pre-adoption frames
    /// under the loser's root without ever taking their epoch as its DH base, and stays on the loser's prekey with its
    /// init attached until the loser answers under the winning root. Each side lists the root it holds first.
    private func resolveRace(
        _ context: OpenContext,
        session: SessionState,
        initial: RatchetInit,
        now: Int64
    ) throws(RatchetCryptoError) -> ResolvedSession? {
        guard let prekey = context.prekeyForInit else {
            return nil
        }
        let peerRoot = try respond(context, prekey: prekey, initial: initial)
        var resolved = session
        resolved.prevRootExpiresAt = now &+ Self.previousRootMilliseconds
        resolved.peerInitEphPub = initial.eph
        if session.peerId < context.selfNodeId {
            // We lose: adopt the winner's root, as its responder, and leave our own draining.
            resolved.confirmed = true
            resolved.weAreInitiator = false
            resolved.root = peerRoot
            resolved.prevRoot = session.root
            resolved.prevRootWeAreInitiator = true
            // The root we leave is our own init, never answered: the one root a peer that adopted it can still seal under.
            // Its own stamp, ours (knit-next ADR 026), read before the line below takes the winner's
            // (`RatchetEngine.kt:813-816` at `f018bc8ce`, knit-next ADR 2026-10.4mjm).
            resolved.prevRootOwnInitAt = session.establishedAt
            resolved.establishedAt = initial.at
            resolved.sendEpochPub = nil
            resolved.sendChainKey = nil
            return ResolvedSession(
                session: resolved,
                candidates: [
                    RootCandidate(root: peerRoot, senderIsInitiator: true, active: true),
                    RootCandidate(root: session.root, senderIsInitiator: false, active: false),
                ],
                purge: true
            )
        }
        // We win: keep our root, read the loser's draining, and anchor its init. The loser's root is never ours to reclaim.
        resolved.prevRoot = peerRoot
        resolved.prevRootWeAreInitiator = false
        resolved.prevRootOwnInitAt = nil
        return ResolvedSession(
            session: resolved,
            candidates: [
                RootCandidate(root: session.root, senderIsInitiator: false, active: true),
                RootCandidate(root: peerRoot, senderIsInitiator: true, active: false),
            ],
            purge: false
        )
    }

    /// The stamp of our own init, lost to a race, when a frame that opens under `session`'s draining `prevRoot` moves us
    /// back onto it, else `nil` (`reclaimsPrevRoot`, knit-next `RatchetEngine.kt:926-938` at `f018bc8ce`, its ADR
    /// 2026-10.4mjm): the slot holds that init (``SessionState/prevRootOwnInitAt``), the peer's role under it is responder,
    /// so it adopted our init, and the frame was sealed after the init we lost to (``OpenContext/sealedSinceLostRace``). Only
    /// a peer that adopted our init can seal under it as responder: a race winner reads the loser's root read-only and never
    /// seals under it. The freshness half keeps out a frame the peer sealed under our init before it left it for the root we
    /// then lost to, its restore's reset say, which would put us back on a root the peer no longer holds.
    static func reclaimsPreviousRoot(_ session: SessionState, _ context: OpenContext) -> Int64? {
        guard session.prevRootWeAreInitiator, context.sealedSinceLostRace else {
            return nil
        }
        return session.prevRootOwnInitAt
    }

    /// Back onto our own init, which the peer has answered (`reclaim`, knit-next `RatchetEngine.kt:940-969` at `f018bc8ce`,
    /// its ADR 2026-10.4mjm): `root`, the `prevRoot` we lost the race on, becomes the active root, held as its confirmed
    /// initiator with its own `establishedAt`, `ownInitAt`, our clock (knit-next ADR 026); the root we had adopted drains as
    /// `prevRoot` for a fresh 48 h, and the stamp goes. The DH base and the acks are claims about the era we leave and start
    /// again, and the frame that reclaims sets them through the era effects; `highestPeAcked` restarts with them, or the
    /// retired-base gate would read the reclaimed era's `EPOCH_GONE`s against the left era's ack. The send chain is dropped,
    /// so the next seal opens a new epoch under the reclaimed root and our numbering stays monotone. The peer's init stays
    /// the anchor, so its re-serves stay inert, and `lastResetSentAt` is untouched: it holds our reset floors.
    static func reclaim(_ session: SessionState, root: [UInt8], ownInitAt: Int64, now: Int64) -> SessionState {
        var reclaimed = session
        reclaimed.confirmed = true
        reclaimed.weAreInitiator = true
        reclaimed.root = root
        reclaimed.establishedAt = ownInitAt
        reclaimed.initEphPub = nil
        reclaimed.prevRoot = session.root
        reclaimed.prevRootWeAreInitiator = session.weAreInitiator
        reclaimed.prevRootExpiresAt = now &+ previousRootMilliseconds
        reclaimed.prevRootOwnInitAt = nil
        reclaimed.peerBasePub = nil
        reclaimed.peerBaseEpoch = 0
        reclaimed.highestPeAcked = 0
        reclaimed.sendEpochPub = nil
        reclaimed.sendChainKey = nil
        return reclaimed
    }

    /// X3DH from the responder's side, with the prekey the init names (`respond`, `:707-716`). Throws when X25519
    /// refuses the init's ephemeral or the peer's identity key, as Tink does out of Kotlin's engine.
    func respond(_ context: OpenContext, prekey: SignedPrekey, initial: RatchetInit) throws(RatchetCryptoError) -> [UInt8] {
        try RatchetCrypto.x3dhRespond(
            ikPriv: context.identity.agreementScalar,
            spkPriv: prekey.privateKey,
            peerIkPub: context.peerIdentity.agreementKey,
            peerEkPub: initial.eph
        )
    }
}
