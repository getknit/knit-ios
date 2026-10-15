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
    public func open<Work>(
        _ frame: Frame,
        from peer: PublicKeyBundle,
        now: Int64,
        prekeys: (Int) -> SignedPrekey?,
        alongside: (RatchetEngine.OpenOutcome.Opened) -> Work?
    ) -> Answer<Opening<Work>> {
        var unopened = Opening<Work>.abandoned
        var settlement = Settlement.unchanged(peer.nodeId)
        let unit = transactor.atomically { () -> Opening<Work>? in
            let held = store.session(peer.nodeId).map(RatchetRecords.session)
            let context = context(for: frame.header, from: peer, held: held, now: now, prekeys: prekeys)
            let outcome: RatchetEngine.OpenOutcome
            do {
                outcome = try engine.open(context, header: frame.header, nonce: frame.nonce, ct: frame.ct, aad: frame.aad, now: now)
            } catch {
                unopened = .rejected
                return nil
            }
            switch outcome {
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
                return .opened(plaintext: opened.plaintext, work: work)
            }
        }
        return answer(unit, settlement: settlement, otherwise: unopened)
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
