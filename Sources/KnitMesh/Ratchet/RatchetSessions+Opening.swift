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
    public func open<Work>(
        _ frame: Frame,
        from peer: PublicKeyBundle,
        now: Int64,
        allowEraChange: Bool = true,
        answeredBefore: ([UInt8]) -> Bool = { _ in false },
        prekeys: (Int) -> SignedPrekey?,
        alongside: (RatchetEngine.OpenOutcome.Opened) -> Work?
    ) -> Answer<Opening<Work>> {
        var unopened = Opening<Work>.abandoned
        var settlement = Settlement.unchanged(peer.nodeId)
        let unit = transactor.atomically { () -> Opening<Work>? in
            let held = store.session(peer.nodeId).map(RatchetRecords.session)
            var context = context(for: frame.header, from: peer, held: held, now: now, prekeys: prekeys)
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
                // A replacement adopted, or a race lost: its floor starts, and failures from the era left are moot.
                settlement = .opened(
                    from: peer.nodeId,
                    at: now,
                    adoptedReplacement: opened.delta.purgePeerRecvState,
                    answeredOurInit: Self.answeredOurInit(was: held, next: opened.delta.session)
                )
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
    /// number alone, and our prekey for the init's `pkid`.
    private func context(
        for header: RatchetHeader,
        from peer: PublicKeyBundle,
        held: RatchetEngine.SessionState?,
        now: Int64,
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
            resetRequested: header.flags & RatchetHeader.resetFlag != 0
        )
    }

    /// Whether an open answered our own init: a session we initiated, unconfirmed, now confirmed and still ours, not a race
    /// lost to the peer's, which confirms us as its responder (`answeredOurInit`, `RatchetSessions.kt:386-390`).
    static func answeredOurInit(was: RatchetEngine.SessionState?, next: RatchetEngine.SessionState) -> Bool {
        was?.weAreInitiator == true && was?.confirmed == false && next.confirmed && next.weAreInitiator
    }
}
