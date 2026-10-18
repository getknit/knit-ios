public import KnitCrypto
import KnitStore
import KnitWire

extension RatchetSessions {
    /// A reset's plaintext, always the named v2 form: `MessageContent(body = "", ctl = CTL_SESSION_RESET)`
    /// (`InboundPipeline.kt:1927`), which makes the peer re-seal its recent unacked DMs to us and re-send its group seeds.
    public static let resetPlaintext = MessageContent(body: "", ctl: MessageContent.Control.sessionReset).encoded

    /// What a seal is asked for, the same for a DM and a reset.
    struct SealRequest {
        let plaintext: [UInt8]
        let aad: [UInt8]
        let prekey: PeerPrekey?
        let now: Int64
        let v3: Bool
    }

    /// Seals one DM to `peer`, the pinned bundle whose node id is the peer's, starting a session by X3DH against its
    /// verified `prekey` on first use (`sealDm`, `RatchetSessions.kt:223-277`). The advanced chain, and any epoch the seal
    /// or the initiation minted, are persisted before the envelope is answered: a frame that left with its chain lost
    /// would have the next seal reuse its message key.
    ///
    /// `v3` seals the compact form, for a peer whose pinned profile carries `CAP_CRYPTO_V3` (``CryptoScheme``), with
    /// `plaintext` already laid out for it, `MessageContentV2`; the envelope still carries an empty nonce, so a build
    /// before v3 decodes and carries it.
    public func sealDm(
        to peer: PublicKeyBundle,
        prekey: PeerPrekey?,
        plaintext: [UInt8],
        aad: [UInt8],
        now: Int64,
        v3: Bool = false
    ) -> Answer<Sealing> {
        let request = SealRequest(plaintext: plaintext, aad: aad, prekey: prekey, now: now, v3: v3)
        var unsealed = Sealing.unavailable
        let unit = transactor.atomically { () -> Sealing? in
            let held = store.session(peer.nodeId).map(RatchetRecords.session)
            do {
                var initiation: RatchetEngine.Initiation?
                if held == nil {
                    guard let prekey else {
                        return nil
                    }
                    initiation = try engine.initiate(
                        peerId: peer.nodeId, identity: identity, peerIdentity: peer, peerPrekey: prekey, now: now)
                }
                guard let session = initiation?.session ?? held,
                    let sealed = try commitSeal(session, minted: initiation?.epoch, request: request, resetAt: nil)
                else {
                    return nil
                }
                let version = v3 ? EncEnvelope.Version.compactRatchet : EncEnvelope.Version.ratchet
                return .sealed(Self.envelope(sealed, version: version, flags: sealed.header.flags))
            } catch {
                unsealed = .refusedKey
                refused(peer.nodeId, error)
                return nil
            }
        }
        return answer(unit, settlement: .unchanged(peer.nodeId), otherwise: unsealed)
    }

    /// Seals a session reset toward `peer`, the marker ``resetPlaintext`` names, unless the peer would refuse it
    /// (`sealResetDm`, `RatchetSessions.kt:313-384`, knit-next ADR 2026-09.qerd): ``RatchetResetPolicy/plan(for:prekeyId:now:cause:answeredAt:)``
    /// decides from the session held, its persisted `lastResetSentAt`, and when the peer answered our own init.
    ///
    /// - A re-root is a fresh X3DH init replacing the session, flagged `FLAG_RESET`: our numbering restarts at 1, so its
    ///   first epoch replaces the dead era's key of that number (knit-next ADR 027), the old root drains as `prevRoot` for
    ///   48 h, and our receive state goes with the era we leave.
    /// - A mark is the marker sealed under the session held, its header flagged only while an init rides, the one place a
    ///   receiver reads the flag.
    ///
    /// Every reset seals v2, the most compatible form toward a peer that may have reinstalled (`RatchetSessions.kt:471-492`),
    /// and stamps `lastResetSentAt`, on the row and in memory. `plaintext` is ``resetPlaintext`` but for a test.
    public func sealResetDm(
        to peer: PublicKeyBundle,
        prekey: PeerPrekey?,
        plaintext: [UInt8],
        aad: [UInt8],
        now: Int64,
        cause: RatchetResetPolicy.Cause = .onDemand
    ) -> Answer<ResetSealing> {
        guard let prekey else {
            return .settled(.noPrekey)
        }
        let request = SealRequest(plaintext: plaintext, aad: aad, prekey: prekey, now: now, v3: false)
        var unsealed = ResetSealing.noPrekey
        var settlement = Settlement.unchanged(peer.nodeId)
        let unit = transactor.atomically { () -> ResetSealing? in
            let held = store.session(peer.nodeId).map(RatchetRecords.session)
            let plan = RatchetResetPolicy.plan(for: held, prekeyId: prekey.id, now: now, cause: cause, answeredAt: confirmedAt[peer.nodeId])
            if case .decline(let reason) = plan.action {
                unsealed = .declined(reason: reason, plan: plan)
                return nil
            }
            do {
                guard let reset = try sealReset(plan, held: held, to: peer, prekey: prekey, request: request) else {
                    return nil
                }
                settlement = .reset(to: peer.nodeId, at: now, reRooted: reset.reRooted)
                // The flag rides only with an init, the one place a receiver reads it (`RatchetSessions.kt:436`).
                let flags = reset.sealed.header.initial == nil ? 0 : RatchetHeader.resetFlag
                return .sealed(Self.envelope(reset.sealed, version: EncEnvelope.Version.ratchet, flags: flags), plan: plan)
            } catch {
                unsealed = .refusedKey
                refused(peer.nodeId, error)
                return nil
            }
        }
        return answer(unit, settlement: settlement, otherwise: unsealed)
    }

    /// The reset `plan` decided, sealed and committed inside the caller's unit: the marker under the session `held`
    /// (`markReset`, `RatchetSessions.kt:424-438`), or a fresh initiation replacing it (`reRoot`, `:440-469`), which keeps
    /// the old root draining for 48 h and purges our receive state with the era we leave. `nil` when the engine will not
    /// seal under the session held.
    private func sealReset(
        _ plan: RatchetResetPolicy.Plan,
        held: RatchetEngine.SessionState?,
        to peer: PublicKeyBundle,
        prekey: PeerPrekey,
        request: SealRequest
    ) throws(RatchetCryptoError) -> (sealed: RatchetEngine.SealResult, reRooted: Bool)? {
        if plan.action == .mark, let held {
            return try commitSeal(held, minted: nil, request: request, resetAt: request.now).map { (sealed: $0, reRooted: false) }
        }
        let initiation = try engine.initiate(
            peerId: peer.nodeId, identity: identity, peerIdentity: peer, peerPrekey: prekey, now: request.now)
        var fresh = initiation.session
        fresh.prevRoot = held?.root
        fresh.prevRootWeAreInitiator = held?.weAreInitiator ?? false
        fresh.prevRootExpiresAt = held == nil ? 0 : request.now &+ RatchetEngine.previousRootMilliseconds
        // Abandon our receive side with the root, as the peer drops its rows when it adopts this init
        // (`RatchetSessions.kt:459-463`); since the root tag this is hygiene.
        store.purgeReceiveState(peer.nodeId)
        return try commitSeal(fresh, minted: initiation.epoch, request: request, resetAt: request.now).map { (sealed: $0, reRooted: true) }
    }

    /// Seals `request` under `session` and stores the advanced session, stamped with `resetAt` for a reset, with the epoch
    /// the seal or an initiation minted, inside the caller's unit (`store.commitSend`, `RatchetSessions.kt:259`, `:433`,
    /// `:464`). `nil` when the engine will not seal: a new epoch due with no base, or a session missing its chain or init.
    ///
    /// The request's prekey reaches the engine through ``RatchetEngine/prekeyBase(_:peerPrekey:)``, as every Kotlin seal
    /// site passes it (`sealDm`, `sealResetDm`'s mark, knit-next `RatchetSessions.kt:281`, `:461` at `4f3cd995`,
    /// #174; its re-root passes the fresh session's own prekey, which the rule hands through unchanged): a row an older
    /// build initiated, holding no base, seals a new epoch only while the pinned prekey is still the one its init names,
    /// and otherwise answers `nil`, the caller's fallback.
    func commitSeal(
        _ session: RatchetEngine.SessionState,
        minted: RatchetEngine.LocalEpoch?,
        request: SealRequest,
        resetAt: Int64?
    ) throws(RatchetCryptoError) -> RatchetEngine.SealResult? {
        let sealing = try engine.seal(
            session,
            plaintext: request.plaintext,
            aad: request.aad,
            peerPrekey: RatchetEngine.prekeyBase(session, peerPrekey: request.prekey),
            now: request.now,
            v3: request.v3
        )
        guard let sealed = sealing else {
            return nil
        }
        var advanced = sealed.session
        advanced.lastResetSentAt = resetAt ?? advanced.lastResetSentAt
        store.commitSend(RatchetRecords.record(advanced), newLocalEpoch: (minted ?? sealed.newLocalEpoch).map { RatchetRecords.record($0) })
        return sealed
    }

    /// Logs a seal toward `peer` that X25519 refused a key for (`refusedAsNull`, knit-next `RatchetSessions.kt:508-526` at
    /// `4f3cd995`, #172): a peer can sign a low-order point as its prekey, or publish one as its identity key. The seal
    /// answers ``Sealing/refusedKey`` with nothing persisted, so its caller takes the fallback it takes without a prekey.
    private func refused(_ peer: NodeId, _ error: any Error) {
        log.log(.warning, "mesh cannot seal to \(peer): X25519 refused a key (\(error))")
    }

    /// The envelope a seal goes out in, its header flagged as asked: the engine writes `flags` 0, and a reset's flag is
    /// the session layer's (`RatchetSessions.kt:260-276`, `:472-492`).
    static func envelope(_ sealed: RatchetEngine.SealResult, version: Int, flags: Int) -> EncEnvelope {
        var header = sealed.header
        header.flags = flags
        return EncEnvelope(version: version, nonce: sealed.nonce ?? [], ct: sealed.ct, keys: [], ratchet: header)
    }
}
