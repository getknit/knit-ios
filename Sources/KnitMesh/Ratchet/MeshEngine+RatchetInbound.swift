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
/// A frame that opened and committed as its first verdict, its header still carrying the sender's init, is answered
/// with our sealed profile (``answerInit(in:from:)``, phase P5e), the frame that confirms the sender's side.
///
/// A frame our own custody hands back at start is only delivered (``RatchetInbound/Origin/startReplay``):
/// its verdict, if it had one, came before the restart, and the floors that judged it died with the process. Its failure
/// is counted under its reason alone, an init the held session has not resolved moves no era, a reaction or a profile
/// applies nothing, since the clamp its first open met cannot be reproduced, and an init it carries is not answered
/// again. Kotlin replays nothing from its own custody, so it never meets such a frame.
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
    ///
    /// A group key for a group we hold no row for, or from a sender we hold as departed, is decided before anything commits,
    /// as Kotlin decides it on its peek (`holdGroupKeyForUnknownGroup`, `:1058`; phase P6a2): the open is abandoned with the
    /// chain where it was, and the seed pins the roster it carries or parks (``seedAwaitsRoster(_:_:_:sender:route:)``).
    func handleRatchetDirect(_ envelope: RelayEnvelope, _ enc: EncEnvelope, sender: NodeId, route: RatchetInbound.Route) {
        openRatchetDirect(envelope, enc, sender: sender, route: route, parksSeeds: true)
    }

    /// ``handleRatchetDirect(_:_:sender:route:)``'s open. `parksSeeds` is false for the open that follows a seed's wait,
    /// which takes the ordinary path whatever the roster then says.
    func openRatchetDirect(_ envelope: RelayEnvelope, _ enc: EncEnvelope, sender: NodeId, route: RatchetInbound.Route, parksSeeds: Bool) {
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
        let now = clock.wallMilliseconds()
        // The peer's root generation before the open: a root change committed after it can only make a floored reset's hold
        // stale, never let one outlive its era (`InboundPipeline.kt:1809`, `:2818-2820` at `f018bc8ce`).
        let generation = ratchet.rootGeneration(of: sender)
        let open = DirectOpen(envelope: envelope, header: frame.header, sender: sender, route: route, now: now, generation: generation)
        var decided = DirectArrival.refused(.cannotOpen)
        // The inits of the peer's that a session of ours anchored, kept in the identity's item across a reinstall (ADR
        // 2026-10.wcex), and the one this open anchors, if it does.
        let answeredBefore = { [ring = prekeyRing] (eph: [UInt8]) in ring?.answered(eph, by: sender, now: now) ?? false }
        var anchored: [UInt8]?
        // The era judgements read the envelope's signed `sentAt` as it arrived, never `clampFuture`'s (knit-next ADR 026,
        // `cf447a9b`), as ``unreadable(_:epochGoneBase:)`` does: `InboundPipeline.kt:1810`, `:1833` at `f018bc8ce`.
        let answer = ratchet.open(
            frame,
            from: bundle,
            now: now,
            sentAt: envelope.sentAt,
            allowEraChange: route.origin == .firstVerdict,
            answeredBefore: answeredBefore,
            prekeys: { [ring = prekeyRing] in ring?.prekey(id: $0) },
            alongside: { opened -> RatchetArrival? in
                if let initial = frame.header.initial, opened.delta.session.peerInitEphPub == initial.eph {
                    anchored = initial.eph
                }
                decided = directArrival(OpenedContent(opened, of: enc), envelope, from: sender, route: route, parksSeeds: parksSeeds)
                guard case .arrival(let arrival) = decided else {
                    return nil
                }
                return arrival
            }
        )
        switch answer {
        case .settled(.opened(_, let arrival)):
            committed(arrival, open, answering: true, anchored: anchored)
        case .settled(.openedStale(_, let arrival)):
            // An init kept from a session we lost, read under the roots held: never answered.
            committed(arrival, open, answering: false, anchored: anchored)
        case .settled(.stale(let failure, let resetsAtOnce)):
            resolvedStale(open, failure: failure, resetsAtOnce: resetsAtOnce)
        case .settled(.refused(let failure)):
            refusedOpen(open, failure: failure)
        case .settled(.rejected):
            // X25519 refused the init's ephemeral or the peer's identity key: Kotlin's catch records `DECRYPT_FAILED`, and
            // nothing counts toward a reset (`:976-980`).
            drop(.cannotOpen, envelope)
        case .settled(.abandoned):
            abandoned(open, enc, decided: decided)
        case .joined, .failed:
            // Nothing opens a unit around the inbound path, so a joined answer cannot happen here; were it to, its work
            // could not run before an outer commit this path never sees, so it waits for the replay like a failure.
            failedOpen(envelope, route: route)
        }
    }

    /// The work after a DM ratchet frame's unit committed: the copy a failed unit kept goes, the group facade settles, an
    /// init the header still carries is answered unless `answering` is false, what the frame carried follows, and an init
    /// the open `anchored` is kept in the identity's item. `answering` is false for a frame whose init a session of ours
    /// anchored before a reinstall, which is never answered: the answer is what moves our indexes at the peer (ADR
    /// 2026-10.5sk9's P5e limits, ADR 2026-10.wcex).
    private func committed(_ arrival: RatchetArrival, _ open: DirectOpen, answering: Bool, anchored: [UInt8]?) {
        let (envelope, sender, route) = (open.envelope, open.sender, open.route)
        // Any copy of this id that commits ends the copy a failed unit kept, whatever its origin: a ctl frame has no row for
        // the sweep to find, and opened again past an era change it would apply a second time.
        ratchetReplay.forget(envelope.id)
        // Each DM's open settles before anything else opens, since the group facade's floor reads only what settled.
        settleSeeds(arrival.seeds)
        // An init the header still carries is answered first, once the open has committed, as Kotlin's commit calls
        // `onPeerFrameOpened` before the work after it (`:1059-1067`); never from the start's replay (phase P5e).
        if route.origin == .firstVerdict, answering {
            answerInit(in: open.header, from: sender)
        }
        finish(arrival, envelope, from: sender, via: route.hop)
        if let anchored {
            keepAnsweredInit(anchored, from: sender, now: open.now)
        }
        // A root this commit moved to, or our init it answered, owes our presence keys a pass (ADR 2026-11.prsp).
        notePresenceRootMoved(sender)
    }

    /// An open its body abandoned: a seed waits for its roster, or the frame drops for the reason decided.
    private func abandoned(_ open: DirectOpen, _ enc: EncEnvelope, decided: DirectArrival) {
        if case .awaitsRoster(let seeds) = decided {
            seedAwaitsRoster(open.envelope, enc, seeds, sender: open.sender, route: open.route)
        } else if case .refused(let reason) = decided {
            drop(reason, open.envelope)
        }
    }

    /// Keeps `eph`, the init from `peer` that an open at `now` anchored, in the identity's item, once that open's unit has
    /// committed and never inside one (ADR 2026-10.wcex): a reinstall, which keeps the item and loses the session, then
    /// knows the frames that init rode for what they are. A write that fails changes nothing, and a reinstall before the
    /// next answered open meets them as every earlier build did.
    private func keepAnsweredInit(_ eph: [UInt8], from peer: NodeId, now: Int64) {
        guard var ring = prekeyRing, !ring.answered(eph, by: peer, now: now) else {
            return
        }
        do {
            if try ring.keepAnswered(eph, from: peer, now: now) {
                prekeyRing = ring
            }
        } catch {
            log.log(.warning, "mesh kept no answered init from \(peer): \(error)")
        }
    }

    /// The start's pass, with the switch on (ADR 2026-10.wcex): every init a held session is anchored on and the identity's
    /// item lacks is kept there, in one write, after the store's own unit and outside any other. It covers a keep that
    /// failed, and a process ended between an open's commit and its keep.
    func keepAnchoredInits() {
        guard configuration.ratchet, var ring = prekeyRing, let anchors = ratchet.anchoredInits() else {
            return
        }
        let now = clock.wallMilliseconds()
        do {
            if try ring.keepAnswered(anchors.map { PrekeyRing.AnsweredInit(peer: $0.peer, eph: $0.eph, at: now) }, now: now) {
                prekeyRing = ring
            }
        } catch {
            log.log(.warning, "mesh kept no anchored inits at start: \(error)")
        }
    }

    /// A typed failure of `open`'s frame, counted, and fed to the reset heuristic when it is evidence. A reset our floor
    /// refused is never evidence: it is held, inside this failure, for the re-open once the floor ends (knit-next ADR
    /// 2026-11.sfms, `onRatchetFailure`, `InboundPipeline.kt:2839-2842` at `f018bc8ce`).
    private func refusedOpen(_ open: DirectOpen, failure: RatchetEngine.OpenOutcome.Failed) {
        refused(open.envelope, failure, header: open.header)
        noteSpoolUndelivered(open.envelope, route: open.route)
        if failure == .resetFloored {
            holdFlooredReset(open)
        } else if RatchetInbound.countsTowardReset(failure, route: open.route) {
            unreadable(open, epochGoneBase: failure == .epochGone ? open.header.pe : nil)
        }
    }

    /// `open`'s signed frame, whose init a session of ours anchored before a reinstall, refused with `failure`
    /// (ADR 2026-10.wcex). It proves the peer holds a session we lost, so when `resetsAtOnce` says the session held calls
    /// for it (``RatchetResetPolicy/resetsOnAnsweredInit(_:)``) our flagged reset goes now, through the reset's ordinary
    /// path, its plan and its floors (``sendSessionReset(to:now:cause:)``), and the frame is let past the router once for
    /// the peer's re-seal of it, as a counted failure is. Otherwise, or if that reset declines, it counts toward the
    /// heuristic only as `NO_SESSION`, which the engine answers only while no session is held: with one, it is evidence
    /// about an era we no longer hold. Never at a start's replay, for an unsigned frame, for one a spool served, or for a
    /// floored reset's backlog, as no failure counts there (ADR 2026-11.adrq, P4a).
    private func resolvedStale(_ open: DirectOpen, failure: RatchetEngine.OpenOutcome.Failed, resetsAtOnce: Bool) {
        refused(open.envelope, failure, header: open.header, stale: true)
        noteSpoolUndelivered(open.envelope, route: open.route)
        guard open.route.signed, open.route.origin == .firstVerdict, !open.route.isSpool, open.route.mayBeEvidence else {
            return
        }
        // Whatever follows, the peer may re-seal this id after a reset of either side's: one copy is let past the router,
        // as a counted failure's is (``unreadable(_:epochGoneBase:)``).
        _ = router.reopen(open.envelope.id, now: clock.monotonicMilliseconds())
        if resetsAtOnce {
            switch sendSessionReset(to: open.sender, now: open.now, cause: .unreadable) {
            case .sent:
                log.log(.info, "mesh reset to \(open.sender) at once: \(open.envelope.id) rode an init a lost session of ours answered")
                return
            case .declined(let reason):
                log.log(.info, "mesh no session reset to \(open.sender) at once: \(reason)")
            }
        }
        if failure == .noSession {
            unreadable(open, epochGoneBase: nil)
        }
    }

    /// What a DM ratchet frame that opened as `opened` comes to inside its open's unit (`decryptAndDeliverV2`'s peek,
    /// `InboundPipeline.kt:1043-1058`): what it applies, or why the open is abandoned with its chain index unspent.
    private func directArrival(
        _ opened: OpenedContent, _ envelope: RelayEnvelope, from sender: NodeId, route: RatchetInbound.Route, parksSeeds: Bool
    ) -> DirectArrival {
        // Will not decode, or is newer than this build reads: dropped before the commit (`:1043-1052`).
        guard let content = opened.content else {
            return .refused(.cannotOpen)
        }
        // An unsigned frame is a tick or nothing (`unsignedButNotATick`, `:1761-1768`): a signature stripped off a captured
        // plain DM and sent point to point opens just as well, and must not deliver through this door, which dodges custody
        // and would leave the flooded copy deduplicated away.
        guard route.signed || content.ctl == MessageContent.Control.receipt else {
            return .refused(.unsigned)
        }
        // The roster gate, read inside the unit: a seed that must wait leaves the chain where it was (`:1058`, phase P6a2).
        if parksSeeds, let seeds = GroupRatchetInbound.seeds(in: content), waitsForRoster(seeds, from: sender) {
            return .awaitsRoster(seeds)
        }
        return .arrival(arrival(of: content, envelope, from: sender, origin: route.origin, under: opened.under))
    }

    /// Whether `seeds` from `sender` must wait for a roster, read inside the open's unit, so a store that cannot answer fails
    /// the unit.
    private func waitsForRoster(_ seeds: GroupKeyPayload, from sender: NodeId) -> Bool {
        GroupRatchetInbound.awaitsRoster(stores.groups.group(seeds.groupId), from: sender)
    }

    /// A typed failure (`onRatchetFailure`, `InboundPipeline.kt:1775-1797`), counted under its reason. The header's
    /// fields are the whole diagnosis: which base key could not be found separates two eras from a swept retention window.
    /// `stale` marks a frame whose init a session of ours anchored before a reinstall (ADR 2026-10.wcex).
    private func refused(
        _ envelope: RelayEnvelope, _ failure: RatchetEngine.OpenOutcome.Failed, header: RatchetHeader, stale: Bool = false
    ) {
        drop(RatchetInbound.dropReason(for: failure), envelope)
        let fields = "se=\(header.se) pe=\(header.pe) n=\(header.n) init=\(header.initial != nil)\(stale ? " answered-before" : "")"
        log.log(.info, "mesh ratchet drop \(envelope.id) from \(envelope.senderId): \(failure) \(fields)")
    }

    /// `open`'s signed frame, whose failure is evidence that the session we hold is broken (`InboundPipeline.kt:1798-1828`):
    /// let past the router's dedup once, and fed to the reset heuristic, which sends a reset when it fires. `epochGoneBase`
    /// is the header's `pe` for an `EPOCH_GONE`, which the heuristic's retired-base gate reads (knit-next ADR 2026-10.9wvr).
    ///
    /// A frame that carries the init of the reset we hold floored for its sender, at the root generation read before its
    /// open, is that resetter's own follow-up, sealed under the root we have not adopted yet: it never reaches the heuristic,
    /// or it would fire our own reset meanwhile (`maybeRequestReset`'s `explains`, knit-next `InboundPipeline.kt:2961-2967`
    /// at `f018bc8ce`, its ADR 2026-11.sfms). The re-open replays it.
    private func unreadable(_ open: DirectOpen, epochGoneBase: Int?) {
        let (envelope, sender, now) = (open.envelope, open.sender, open.now)
        // A reset of ours makes the sender seal this very frame again under the same id, which the router would take for
        // the copy custody just served us, for ten minutes: one copy is let through (`:1819-1824`). This opens our gate
        // only: a relay between us that saw the id in its window drops that seal, which is why the sender seals it once
        // more after the window (`resealRecentDirectMessages`, knit-next `InboundPipeline.kt:1943-1948` at `4f3cd995`, knit-next
        // ADR 2026-10.dmgw).
        _ = router.reopen(envelope.id, now: clock.monotonicMilliseconds())
        if explainsByFlooredReset(open) {
            // Kotlin's own line (`InboundPipeline.kt:2965`), new here, so no harness pattern moves.
            log.log(.info, "mesh reset gate: \(envelope.id) from \(sender) rides the reset we hold floored")
            return
        }
        // Outside any unit, as Kotlin runs it before any transaction (`:1041`, `:1835-1856`): inside one it counts nothing.
        // The stamp is the envelope's signed `sentAt` as it arrived, never `clampFuture`'s: a responder's era starts at the
        // peer's own `init.at`, so a clamped stamp would class every live failure from a fast clock as pre-era
        // (`:1897-1899`, knit-next `cf447a9b`).
        let noted = ratchet.noteUndecryptable(
            from: sender, frameId: envelope.id, sentAt: envelope.sentAt, now: now, epochGoneBase: epochGoneBase)
        guard noted else {
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
        noteSpoolUndelivered(envelope, route: route)
        if route.origin == .firstVerdict {
            _ = router.reopen(envelope.id, now: clock.monotonicMilliseconds())
        }
    }
}

/// One DM ratchet frame's open, as the work after it reads it: the frame, its header, its verified sender, the route it
/// came by, and the wall clock the open ran at.
internal struct DirectOpen {
    let envelope: RelayEnvelope
    let header: RatchetHeader
    let sender: NodeId
    let route: RatchetInbound.Route
    let now: Int64
    /// The peer's root generation read before the open (``RatchetSessions/rootGeneration(of:)``).
    let generation: Int
}

/// What a DM ratchet frame opened to inside its open's unit: its plaintext read, or `nil` when it will not decode or is newer
/// than this build reads, and the era the open committed, read from the open's own delta (``OpenedUnder``).
private struct OpenedContent {
    let content: MessageContent?
    let under: OpenedUnder

    /// What `opened` holds, its plaintext read by the version of `enc`, the envelope it came in.
    init(_ opened: RatchetEngine.OpenOutcome.Opened, of enc: EncEnvelope) {
        content = RatchetInbound.content(of: opened.plaintext, v3: enc.version == EncEnvelope.Version.compactRatchet)
        under = OpenedUnder(opened.delta)
    }
}

/// What a DM ratchet frame that opened comes to inside its open's unit.
private enum DirectArrival {
    /// What it applies, and the work for after the commit.
    case arrival(RatchetArrival)
    /// Abandoned, counted under this reason.
    case refused(DropReason)
    /// Abandoned until a roster lets its seeds in (phase P6a2).
    case awaitsRoster(GroupKeyPayload)
}
