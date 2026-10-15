import KnitWire

extension RatchetEngine {
    /// The session a frame is read under and the roots it may open under, in order (`ResolvedSession`, `:351-356`).
    struct ResolvedSession {
        let session: SessionState
        /// The roots to try, each with the epoch sender's role under it.
        let candidates: [RootCandidate]
        /// Whether the resolution changed the root we hold: the receive state it leaves is purged, and the resolving
        /// frame reads nothing stored.
        let purge: Bool
    }

    /// One root a frame may open under (`RootCandidate`, `:363-370`). Only the ``active`` one, the root the resolved
    /// session holds as its own, may move the session's era; a draining `prevRoot`, a race's other root and a late
    /// race loser's are read-only.
    struct RootCandidate {
        let root: [UInt8]
        /// The role, under this root, of whoever sealed the frame.
        let senderIsInitiator: Bool
        let active: Bool
        /// The tag the receive state this root derives carries.
        let tag: Int64

        init(root: [UInt8], senderIsInitiator: Bool, active: Bool) {
            self.root = root
            self.senderIsInitiator = senderIsInitiator
            self.active = active
            tag = RatchetCrypto.rootTag(root)
        }
    }

    /// Applies the frame's init, if any, to the session it should be read under (`resolveSession`, `:512-595`); `nil`
    /// when nothing can read it (no session and no usable init). Throws where Kotlin's `respond` does.
    func resolveSession(_ context: OpenContext, header: RatchetHeader, now: Int64) throws(RatchetCryptoError) -> ResolvedSession? {
        guard let session = context.session else {
            return try establish(context, initial: header.initial)
        }
        var candidates = [RootCandidate(root: session.root, senderIsInitiator: !session.weAreInitiator, active: true)]
        if let prevRoot = session.prevRoot, session.prevRootExpiresAt > now {
            candidates.append(RootCandidate(root: prevRoot, senderIsInitiator: !session.prevRootWeAreInitiator, active: false))
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
        // Both sides initiated: we hold an unconfirmed session we started, and the peer's own init just arrived.
        // Decided by node id, never by `init.at`: two inits can carry one stamp, and both sides must pick one winner
        // (`:544-547`).
        if !session.confirmed, session.weAreInitiator {
            return try resolveRace(context, session: session, initial: initial, now: now)
        }
        // A replacement: the peer lost its state, or reset, and re-initiated. Only an init newer than the session we
        // share (`:548-549`), answerable with a prekey we hold, inside the caller's floor (`:550-552`), and not the
        // race remnant (`:553-570`). The remnant guard refuses an init re-served from an era the peer has already left:
        // we won a race without ever reading the loser's init, so nothing anchors it, and it can come back from custody
        // newer than our session for a whole TTL. Adopting it would defect to the losing root while the peer stays on
        // ours, both confirmed and diverged for good. `FLAG_RESET` is exempt (knit-next ADR 024): a reset is minted
        // fresh, is the only signal a peer that lost its state can send, and abandons the losing root on its side too.
        let replaces = initial.at > session.establishedAt && context.allowReplacement && !Self.isRemnant(session, context)
        if replaces, let prekey = context.prekeyForInit {
            return try replace(session, initial: initial, prekey: prekey, context: context, now: now)
        }
        // Refused is not unread: the remnant's frame is the loser's opening DM, still a real message (#83).
        let remnants = try remnantCandidates(session, header: header, initial: initial, context: context)
        return ResolvedSession(session: session, candidates: candidates + remnants, purge: false)
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
        // We win: keep our root, read the loser's draining, and anchor its init.
        resolved.prevRoot = peerRoot
        resolved.prevRootWeAreInitiator = false
        return ResolvedSession(
            session: resolved,
            candidates: [
                RootCandidate(root: session.root, senderIsInitiator: false, active: true),
                RootCandidate(root: peerRoot, senderIsInitiator: true, active: false),
            ],
            purge: false
        )
    }

    /// X3DH from the responder's side, with the prekey the init names (`respond`, `:707-716`). Throws when X25519
    /// refuses the init's ephemeral or the peer's identity key, as Tink does out of Kotlin's engine.
    private func respond(_ context: OpenContext, prekey: SignedPrekey, initial: RatchetInit) throws(RatchetCryptoError) -> [UInt8] {
        try RatchetCrypto.x3dhRespond(
            ikPriv: context.identity.agreementScalar,
            spkPriv: prekey.privateKey,
            peerIkPub: context.peerIdentity.agreementKey,
            peerEkPub: initial.eph
        )
    }
}
