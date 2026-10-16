import KnitCrypto
import KnitStore
import KnitWire

/// The DM ratchet received in the mesh, with the switch on (ADR 2026-10.5sk9, phase P5a): `decryptAndDeliverV2`,
/// `onRatchetFailure` and `maybeRequestReset` in knit-next's `InboundPipeline.kt` (at `cbf2a487`, `:1008-1104` and
/// `:1775-1856`).
///
/// A DM-form v2 or v3 frame addressed to us opens through ``RatchetSessions`` in one store unit together with everything
/// it carries: the message row and its inline acks, or what a ctl applies (``arrival(of:_:from:)``). That unit is the
/// outermost and fails closed, so nothing is announced, fetched, acknowledged or sent before it commits, and after a
/// failure nothing is at all: the copy that failed is kept and opened again at the next sweep (``RatchetReplay``).
///
/// A frame our own custody hands back at start is only delivered (``RatchetInbound/Origin/startReplay``):
/// its verdict, if it had one, came before the restart, and the floors that judged it died with the process. Its failure
/// is counted under its reason alone, an init the held session has not resolved moves no era, and a reaction or a
/// profile applies nothing, since the clamp its first open met cannot be reproduced. Kotlin replays nothing from its own
/// custody, so it never meets such a frame.
///
/// Kotlin opens in two phases, a peek and then a commit. This port's open is one phase, so what Kotlin decides on the
/// peek before its commit (the plaintext's decode and version, and the unsigned door's last check) is decided inside the
/// unit, where answering `nil` abandons the open with nothing committed: the chain index stays unspent, so a twin of the
/// frame still opens later.
extension MeshEngine {
    /// A DM-form v2 or v3 frame from `sender` addressed to us (`decryptAndDeliverV2`, `InboundPipeline.kt:1008-1104`),
    /// along `route`, which is signed unless it is the unsigned live-link tick. Refused before the engine when malformed,
    /// opened in one unit with what it carries, and on a typed failure counted, and fed to the reset heuristic when it is
    /// evidence.
    func handleRatchetDirect(_ envelope: RelayEnvelope, _ enc: EncEnvelope, sender: NodeId, route: RatchetInbound.Route) {
        // Only a frame addressed to us comes here, so its thread, `env.recipientId.orEmpty()` (`:1036`), is our own id:
        // a canonical id's bytes, the same ones the envelope carries.
        let aad = MessageCrypto.header(id: envelope.id, senderId: envelope.senderId, sentAt: envelope.sentAt, thread: nodeId.string)
        // v2 and v3 are DM-only: one addressed to a group, or with no header, is malformed by construction (`:1017-1028`).
        guard envelope.group == nil, let frame = RatchetInbound.frame(enc, aad: aad) else {
            drop(.ratchetBadHeader, envelope)
            return
        }
        guard let bundle = stores.peers.peer(sender).flatMap({ PublicKeyBundle(encoded: $0.publicKey) }) else {
            // Unreachable in practice: ``verify(_:)`` required the pinned bundle (`:1030-1036`).
            drop(.noSenderKey, envelope)
            return
        }
        let v3 = enc.version == EncEnvelope.Version.compactRatchet
        let ring = prekeyRing
        let now = clock.wallMilliseconds()
        var refusal = DropReason.cannotOpen
        let answer = ratchet.open(
            frame,
            from: bundle,
            now: now,
            allowEraChange: route.origin == .firstVerdict,
            prekeys: { ring?.prekey(id: $0) },
            alongside: { opened -> RatchetArrival? in
                // Will not decode, or is newer than this build reads: dropped before the commit (`:1043-1052`).
                guard let content = RatchetInbound.content(of: opened.plaintext, v3: v3) else {
                    return nil
                }
                // An unsigned frame is a tick or nothing (`unsignedButNotATick`, `:1761-1768`): a signature stripped off a
                // captured plain DM and sent point to point opens just as well, and must not deliver through this door,
                // which dodges custody and would leave the flooded copy deduplicated away.
                guard route.signed || content.ctl == MessageContent.Control.receipt else {
                    refusal = .unsigned
                    return nil
                }
                return arrival(of: content, envelope, from: sender, origin: route.origin)
            }
        )
        switch answer {
        case .settled(.opened(_, let arrival)):
            // Any copy of this id that commits ends the copy a failed unit kept, whatever its origin: a ctl frame has no
            // row for the sweep to find, and opened again past an era change it would apply a second time.
            ratchetReplay.forget(envelope.id)
            finish(arrival, envelope, from: sender, via: route.hop)
        case .settled(.refused(let failure)):
            refused(envelope, failure, header: frame.header)
            if RatchetInbound.countsTowardReset(failure, route: route) {
                unreadable(envelope, from: sender, now: now)
            }
        case .settled(.rejected):
            // X25519 refused the init's ephemeral or the peer's identity key: Kotlin's catch records `DECRYPT_FAILED`, and
            // nothing counts toward a reset (`:976-980`).
            drop(.cannotOpen, envelope)
        case .settled(.abandoned):
            drop(refusal, envelope)
        case .joined, .failed:
            // Nothing opens a unit around the inbound path, so a joined answer cannot happen here; were it to, its work
            // could not run before an outer commit this path never sees, so it waits for the replay like a failure.
            failedOpen(envelope, route: route)
        }
    }

    /// A typed failure (`onRatchetFailure`, `InboundPipeline.kt:1775-1797`), counted under its reason. The header's
    /// fields are the whole diagnosis: which base key could not be found separates two eras from a swept retention window.
    private func refused(_ envelope: RelayEnvelope, _ failure: RatchetEngine.OpenOutcome.Failed, header: RatchetHeader) {
        drop(RatchetInbound.dropReason(for: failure), envelope)
        let fields = "se=\(header.se) pe=\(header.pe) n=\(header.n) init=\(header.initial != nil)"
        log.log(.info, "mesh ratchet drop \(envelope.id) from \(envelope.senderId): \(failure) \(fields)")
    }

    /// A signed frame whose failure is evidence that the session we hold is broken (`InboundPipeline.kt:1798-1828`): let
    /// past the router's dedup once, and fed to the reset heuristic, which sends a reset when it fires.
    private func unreadable(_ envelope: RelayEnvelope, from sender: NodeId, now: Int64) {
        // A reset of ours makes the sender seal this very frame again under the same id, which the router would take for
        // the copy custody just served us, for ten minutes: one copy is let through (`:1819-1824`).
        _ = router.reopen(envelope.id, now: clock.monotonicMilliseconds())
        // Outside any unit, as Kotlin runs it before any transaction (`:1041`, `:1835-1856`): inside one it counts nothing.
        // The stamp is the envelope's signed `sentAt` as it arrived, never `clampFuture`'s: a responder's era starts at the
        // peer's own `init.at`, so a clamped stamp would class every live failure from a fast clock as pre-era
        // (`:1897-1899`, knit-next `cf447a9b`).
        guard ratchet.noteUndecryptable(from: sender, frameId: envelope.id, sentAt: envelope.sentAt, now: now) else {
            return
        }
        if case .declined(let reason) = sendSessionReset(to: sender, now: now, cause: .unreadable) {
            log.log(.info, "mesh no session reset to \(sender): \(reason)")
        }
    }

    /// A frame whose open's unit failed (P5a's own): nothing was delivered or acknowledged and nothing in memory moved.
    /// The copy that failed is kept, with the route it came by, and opened again at the next sweep
    /// (``replayFailedRatchetOpens()``). Custody cannot stand in for it: it keeps the first bytes stored under an id, which
    /// for a peer's re-seal after a reset is the seal that could not open, it never held a copy handed us point to point,
    /// and it lists what it holds in our digest, so no neighbour serves it again. A first verdict's id is also let past the
    /// router's dedup once, so a copy a neighbour's back-fill brings before the sweep is not taken for the one already
    /// seen. A start's replay came out of our own custody and reopens nothing.
    private func failedOpen(_ envelope: RelayEnvelope, route: RatchetInbound.Route) {
        drop(.storeRefused, envelope)
        log.log(.warning, "mesh ratchet frame \(envelope.id) from \(envelope.senderId) left for the replay: a store failed")
        ratchetReplay.keep(envelope, route: route)
        if route.origin == .firstVerdict {
            _ = router.reopen(envelope.id, now: clock.monotonicMilliseconds())
        }
    }

    /// Opens again every copy whose unit failed since the last sweep, oldest first, by the route it came: for a frame off
    /// a link, its first verdict. A copy another copy of its id already committed is gone (``RatchetReplay/forget(_:)``).
    /// The rest are decided by their row, read in a unit of its own: a row lets the copy go, so a DM delivered another
    /// way, or deleted since, is not acknowledged again; a read the store fails fails the unit and keeps the copy; with no
    /// row, the copy opens again. Each goes through ``handleChat(_:via:signed:origin:)`` as it came, so the router's
    /// dedup, which marked its id when it arrived, is no part of it.
    func replayFailedRatchetOpens() {
        let kept = ratchetReplay.take()
        guard configuration.ratchet, !kept.isEmpty else {
            return
        }
        for copy in kept {
            // The body answers the copy to open again, or none once its row exists, never `nil`, which would abandon the unit.
            let unread = stores.transactor.atomically { () -> RatchetReplay.Kept?? in
                .some(stores.messages.contains(copy.envelope.id) ? nil : copy)
            }
            switch unread {
            case .committed(let copy?):
                handleChat(copy.envelope, via: copy.route.hop, signed: copy.route.signed, origin: copy.route.origin)
            case .committed(nil):
                continue
            case .joined, .abandoned, .failed:
                log.log(.warning, "mesh ratchet frame \(copy.envelope.id) kept for the next replay: a store failed")
                ratchetReplay.keep(copy.envelope, route: copy.route)
            }
        }
    }

    /// Opens again, at start, every ratchet DM to us that our own custody holds with no row, oldest first: a failed unit's
    /// copy died with the process that kept it, and custody holds the first bytes stored under its id. It only delivers
    /// (``RatchetInbound/Origin/startReplay``): it holds the era, and applies no reaction and no profile. Most of what it
    /// finds is machinery already opened: a ctl frame from the era we hold drops as `DUPLICATE`, and one from an era the
    /// pair has since left can open again under the root that era left draining, since leaving it purged the receive
    /// state that spent it; a receipt then flips nothing new, and a reset's marker applies nothing. The rest are frames a
    /// failed unit or a closed switch left unread.
    func replayCustodiedRatchetMessages() {
        guard configuration.ratchet else {
            return
        }
        let me = ExactKey(nodeId.string)
        for carried in stores.custody.liveFrames(now: clock.wallMilliseconds()).reversed() {
            let envelope = carried.envelope
            guard envelope.isDirect, envelope.recipientId.map(ExactKey.init) == me, !stores.messages.contains(envelope.id),
                let enc = (try? ChatContent(decoding: envelope.payload))?.enc, RatchetInbound.isDirectRatchet(enc)
            else {
                continue
            }
            // Custody verified it, and the chat door reads the block list and the rest again. Custody kept no hop, so a
            // photo it carries is asked of its author first.
            handleChat(envelope, via: nil, signed: !carried.sig.isEmpty, origin: .startReplay)
        }
    }

    /// The ratchet's retention sweep, at start and then hourly, with the switch on: in a unit of its own, never inside a
    /// DM's, since on the database it truncates the write-ahead log once it commits, and no send may wait behind that.
    func sweepRatchet() {
        guard configuration.ratchet else {
            return
        }
        if !ratchet.sweep(now: clock.wallMilliseconds()) {
            log.log(.warning, "mesh ratchet sweep failed: a store failed")
        }
    }
}
