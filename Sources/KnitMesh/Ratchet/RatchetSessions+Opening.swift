public import KnitCrypto
import KnitStore
import KnitWire

extension RatchetSessions {
    /// Opens one DM frame from `peer`, the pinned bundle that verified it, and commits what the open changed together
    /// with what `alongside` writes, in one store unit (`peekOpen` and `commitOpen`, `RatchetSessions.kt:161-221`, as one
    /// phase). The session, the receive chain, the skipped keys inserted, the one spent by its root's tag and the purge of
    /// an era left behind all stand with the caller's message row, or none of them does: a chain advanced past a message
    /// nobody holds would have spent that message's key for good.
    ///
    /// `prekeys` finds our signed prekey by id. The init's prekey is looked up by the id the init names
    /// (`RatchetSessions.kt:140`), and one under another id counts as none: the engine trusts the prekey it is handed, and a
    /// wrong one would derive a wrong root whose `AEAD_FAIL` counts toward a reset.
    ///
    /// `alongside` runs inside the unit once the frame has opened, with the plaintext; it writes stores and nothing else,
    /// and answers the work for after the commit, or `nil` to abandon the unit with the open. An init that replaces the
    /// session is adopted only past the replacement floor this keeps per peer (``RatchetResetPolicy/replacementFloor(flags:)``),
    /// and that floor starts, and the heuristic's ids are dropped, only once the unit commits.
    ///
    /// `allowEraChange` is `false` for a frame the engine's own custody hands back at start (phase P5a): an init the held
    /// session has not resolved then neither races nor replaces it, whatever the floors say, and the frame is read under
    /// the roots held (``RatchetEngine/OpenContext/allowEraChange``). With no session held, an init still establishes one.
    ///
    /// `answeredBefore` says whether an ephemeral is one of `peer`'s inits a session of ours anchored, as the identity's item
    /// keeps them (``PrekeyRing/answered(_:by:now:)``, ADR 2026-10.wcex). A frame whose init it names, and which the session
    /// held is not anchored on, is resolved stale: it establishes, races and replaces nothing, a failure answers
    /// ``Opening/stale(_:resetsAtOnce:)`` rather than ``Opening/refused(_:)``, and a read-only open
    /// ``Opening/openedStale(plaintext:work:)``, whose init the caller never answers.
    ///
    /// `sentAt` is the frame's signed envelope stamp exactly as it arrived, the sender's clock, never `clampFuture`'s: the
    /// two era judgements read it against the session the unit holds (``predates(_:sentAt:)`` and
    /// ``sealedSinceLostRace(_:sentAt:)``, `contextFor`, knit-next `RatchetSessions.kt:181-221` at `f018bc8ce`). `nil`, a
    /// vector replay's, qualifies for neither, as Kotlin's talk frames pass none. It has no default, so no door, the re-open
    /// of a held reset included, can leave both judgements off by leaving it out.
    public func open<Work>( // swiftlint:disable:this function_parameter_count - `sentAt` has no default on purpose (above)
        _ frame: Frame,
        from peer: PublicKeyBundle,
        now: Int64,
        sentAt: Int64?,
        allowEraChange: Bool = true,
        answeredBefore: ([UInt8]) -> Bool = { _ in false },
        prekeys: (Int) -> SignedPrekey?,
        alongside: (RatchetEngine.OpenOutcome.Opened) -> Work?
    ) -> Answer<Opening<Work>> {
        var unopened = Opening<Work>.abandoned
        var settlement = Settlement.unchanged(peer.nodeId)
        let unit = transactor.atomically { () -> Opening<Work>? in
            let held = store.session(peer.nodeId).map(RatchetRecords.session)
            var context = context(for: frame.header, from: peer, held: held, now: now, sentAt: sentAt, prekeys: prekeys)
            context.allowEraChange = allowEraChange
            guard let (outcome, stale) = verdict(on: frame, context: context, held: held, now: now, answeredBefore: answeredBefore) else {
                unopened = .rejected
                return nil
            }
            switch outcome {
            case .failed(let failure) where stale:
                unopened = .stale(failure, resetsAtOnce: RatchetResetPolicy.resetsOnAnsweredInit(held))
                return nil
            case .failed(let failure):
                unopened = .refused(failure)
                return nil
            case .opened(let opened):
                store.applyOpen(RatchetRecords.record(opened.delta), from: peer.nodeId, se: frame.header.se, n: frame.header.n)
                guard let work = alongside(opened) else {
                    return nil
                }
                settlement = Self.settlement(opened.delta, held: held, peer: peer.nodeId, now: now)
                return stale ? .openedStale(plaintext: opened.plaintext, work: work) : .opened(plaintext: opened.plaintext, work: work)
            }
        }
        return answer(unit, settlement: settlement, otherwise: unopened)
    }

    /// The engine's verdict on `frame` under `context`, and whether its init is one a session of ours anchored before
    /// (``isAnsweredBefore(_:held:context:now:answeredBefore:)``); `nil` when X25519 refused a key in an X3DH respond,
    /// where Tink throws out of Kotlin's engine.
    private func verdict(
        on frame: Frame,
        context: RatchetEngine.OpenContext,
        held: RatchetEngine.SessionState?,
        now: Int64,
        answeredBefore: ([UInt8]) -> Bool
    ) -> (outcome: RatchetEngine.OpenOutcome, stale: Bool)? {
        var context = context
        do {
            let stale = try isAnsweredBefore(frame.header.initial, held: held, context: context, now: now, answeredBefore: answeredBefore)
            context.initAnsweredBefore = stale
            return (try engine.open(context, header: frame.header, nonce: frame.nonce, ct: frame.ct, aad: frame.aad, now: now), stale)
        } catch {
            return nil
        }
    }

    /// Whether `initial` is an init of the peer's that a session of ours anchored before and no longer holds, read in the
    /// open's unit with the session `held` it compares, so a store that cannot answer fails the open (ADR 2026-10.wcex):
    /// `answeredBefore` keeps its ephemeral, `held` is not anchored on it, and the era it founded is not `held`'s draining
    /// previous root. That last is the case of a session we reset or replaced ourselves, which still holds the era, and
    /// keeps Kotlin's rules, the race among them: only an era a reinstall lost is read as stale.
    private func isAnsweredBefore(
        _ initial: RatchetInit?,
        held: RatchetEngine.SessionState?,
        context: RatchetEngine.OpenContext,
        now: Int64,
        answeredBefore: ([UInt8]) -> Bool
    ) throws(RatchetCryptoError) -> Bool {
        guard let initial, held?.peerInitEphPub != initial.eph, answeredBefore(initial.eph) else {
            return false
        }
        guard let held else {
            return true
        }
        return try !engine.derivesPreviousRoot(context, session: held, initial: initial, now: now)
    }

    /// What the engine reads for a frame (`contextFor`, `RatchetSessions.kt:124-159`): the session, every chain for its
    /// `se` and every skipped key for its `(se, n)` whatever root derived them, our epoch the header's `pe` names, by
    /// number alone, and our prekey for the init's `pkid`. The two era judgements read the frame's raw signed `sentAt`
    /// against the session `held`, here beside the rest, as Kotlin's `contextFor` judges them (`RatchetSessions.kt:201-202`
    /// at `f018bc8ce`).
    private func context( // swiftlint:disable:this function_parameter_count - Kotlin's `contextFor` takes the stamp too (`:181-188`)
        for header: RatchetHeader,
        from peer: PublicKeyBundle,
        held: RatchetEngine.SessionState?,
        now: Int64,
        sentAt: Int64?,
        prekeys: (Int) -> SignedPrekey?
    ) -> RatchetEngine.OpenContext {
        RatchetEngine.OpenContext(
            selfNodeId: identity.nodeId,
            peerId: peer.nodeId,
            session: held,
            recvEpochs: store.recvEpochs(peer.nodeId, epoch: header.se).map(RatchetRecords.recvEpoch),
            skippedKeys: store.skippedKeys(peer.nodeId, epoch: header.se, index: header.n).map(RatchetRecords.skippedKey),
            ownBasePrivateKey: header.pe >= 1 ? store.localEpochPrivateKey(peer.nodeId, epoch: header.pe) : nil,
            identity: identity,
            peerIdentity: peer,
            prekeyForInit: header.initial.flatMap { initial in prekeys(initial.pkid).flatMap { $0.id == initial.pkid ? $0 : nil } },
            allowReplacement: now &- (lastReplacementAt[peer.nodeId] ?? 0) >= RatchetResetPolicy.replacementFloor(flags: header.flags),
            resetRequested: header.flags & RatchetHeader.resetFlag != 0,
            predatesSession: Self.predates(held, sentAt: sentAt),
            sealedSinceLostRace: Self.sealedSinceLostRace(held, sentAt: sentAt)
        )
    }

    /// What an open that committed `delta` over the session `held`, from `peer` at `now`, moves in memory once its unit
    /// commits (`commitOpen`, knit-next `RatchetSessions.kt:293-311` at `f018bc8ce`). A replacement adopted, a race lost or
    /// our init reclaimed: its floor starts, and failures from the era left are moot. A reclaim is our init answered too: the
    /// peer adopted it, as a replacement of the root we lost to, no later than it sealed this frame, so its floor runs as
    /// after any answer, and our heuristic's re-root waits it out. And when the peer took our init as a replacement of a
    /// session of its own, a reclaim or ``peerReplacedWith(_:)``, its floor runs from the answer for every cause but
    /// after-wipe (the sender's `replacedAt`, `:304-306`, the 2026-11-01 amendment to knit-next ADR 2026-09.qerd).
    static func settlement(_ delta: RatchetEngine.OpenDelta, held: RatchetEngine.SessionState?, peer: NodeId, now: Int64) -> Settlement {
        let answered = answeredOurInit(was: held, next: delta.session)
        var settlement = Settlement.opened(
            from: peer, at: now, adoptedReplacement: delta.purgePeerRecvState, answeredOurInit: answered || delta.reclaimed)
        settlement.movedRow = movesScopes(was: held, next: delta.session)
        settlement.reclaimed = delta.reclaimed
        settlement.peerReplaced = delta.reclaimed || (answered && held.map(peerReplacedWith) == true)
        return settlement
    }

    /// Whether an open moved what ``dmScopes(now:)`` derives from the row: its root, its previous root and that root's
    /// drain, or its confirmation (ADR 2026-11.adrq, P4a).
    static func movesScopes(was: RatchetEngine.SessionState?, next: RatchetEngine.SessionState) -> Bool {
        guard let was else {
            return true
        }
        return was.root != next.root || was.confirmed != next.confirmed || was.prevRoot != next.prevRoot
            || was.prevRootExpiresAt != next.prevRootExpiresAt
    }

    /// Whether an open answered our own init: a session we initiated, unconfirmed, now confirmed and still ours, not a race
    /// lost to the peer's, which confirms us as its responder (`answeredOurInit`, `RatchetSessions.kt:386-390`). A reclaim
    /// is never this, since the race loser it starts from is a confirmed responder; the open reads it beside this.
    static func answeredOurInit(was: RatchetEngine.SessionState?, next: RatchetEngine.SessionState) -> Bool {
        was?.weAreInitiator == true && was?.confirmed == false && next.confirmed && next.weAreInitiator
    }

    /// Whether the peer, answering our init on the row `was`, took it as a replacement of a session of its own, so its reset
    /// floor started (`peerReplacedWith`, knit-next `RatchetSessions.kt:642-650` at `f018bc8ce`, the 2026-11-01 amendment to
    /// its ADR 2026-09.qerd): the init was a reset or a marker, a stamp at or past `establishedAt` as the reset plan reads
    /// it, which a plain first seal leaves at 0, or we had resolved the peer's own init and won the race, which the peer
    /// resolves by adopting ours and purging. A first contact the peer established is neither. Our row, our clock.
    static func peerReplacedWith(_ was: RatchetEngine.SessionState) -> Bool {
        (was.lastResetSentAt > 0 && was.lastResetSentAt >= was.establishedAt) || was.peerInitEphPub != nil
    }

    /// Whether a frame signed at `sentAt`, the sender's clock, was sealed before the session `held` began, a session we
    /// initiated: more than the skew bound before its `establishedAt`, our own clock there (`predates`, knit-next
    /// `RatchetSessions.kt:1071-1082` at `f018bc8ce`, knit-next ADR 026's initiator rule). The engine reads it only for an
    /// init that derives our draining `prevRoot` (knit-next ADR 2026-10.j67x's rule 2). A session the peer started is never
    /// judged, and an unknown stamp is never before.
    static func predates(_ held: RatchetEngine.SessionState?, sentAt: Int64?) -> Bool {
        guard let held, let sentAt, held.weAreInitiator else {
            return false
        }
        return sentAt < held.establishedAt &- WireProtocol.maxFutureSkewMilliseconds
    }

    /// Whether a frame signed at `sentAt` was sealed after the init we lost a race to (`sealedSinceLostRace`, knit-next
    /// `RatchetSessions.kt:1084-1097` at `f018bc8ce`, its ADR 2026-10.4mjm): only a session `held` holding our own abandoned
    /// init in its `prevRoot` is judged (``RatchetEngine/SessionState/prevRootOwnInitAt``), where `establishedAt` is the
    /// winning init's `at`, copied from that init, so both stamps are the peer's clock. Strictly more than the skew bound
    /// past it: a frame the peer sealed under our init before it moved on to the root we lost to is never fresh. An unknown
    /// stamp is never fresh.
    static func sealedSinceLostRace(_ held: RatchetEngine.SessionState?, sentAt: Int64?) -> Bool {
        guard let held, held.prevRootOwnInitAt != nil, let sentAt else {
            return false
        }
        return sentAt > held.establishedAt &+ WireProtocol.maxFutureSkewMilliseconds
    }
}
