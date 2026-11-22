import KnitCrypto
import KnitStore
import KnitWire

/// The peer resets our replacement floor refused, held and opened again once the floor ends (knit-next ADR 2026-11.sfms,
/// #251; ADR 2026-10.5sk9's P9b amendment): `onRatchetFailure`'s hold, `maybeRequestReset`'s `explains` and
/// `dueFlooredResets` in knit-next's `InboundPipeline.kt`, and `reopenFlooredResets` with its backlog replay in
/// `MeshManager.kt`, at `f018bc8ce`. The pure state is ``FlooredResets``.
extension MeshEngine {
    /// Holds `open`'s frame, a reset our floor refused for a root we never held (`RESET_FLOORED`), until the 60-second
    /// re-offer opens it again (`holdFlooredReset`, `InboundPipeline.kt:2883-2902`). Synchronously, inside the failure that
    /// refused it, so a replayed reset that floors again holds before its follow-ups replay. Only a signed frame, as it came
    /// (``RatchetInbound/Route/wire``): the flag rides outside a v2 frame's AEAD, so the signature is what makes it the
    /// peer's. The hold keeps the route's source, and the root generation read before the open. At the start's replay too,
    /// whose open moved no era: the re-open runs it as the first verdict it never had in this process.
    func holdFlooredReset(_ open: DirectOpen) {
        let (envelope, sender) = (open.envelope, open.sender)
        guard open.route.signed, let wire = open.route.wire, !wire.sig.isEmpty, let eph = open.header.initial?.eph else {
            log.log(.info, "mesh no hold for floored reset \(envelope.id) from \(sender): not a signed frame held whole")
            return
        }
        let held = FlooredResets.Held(
            wire: wire,
            envelope: envelope,
            source: open.route.source,
            initEph: eph,
            generation: open.generation,
            mayBeEvidence: open.route.mayBeEvidence && open.route.origin == .firstVerdict
        )
        switch flooredResets.hold(held, for: sender) {
        case .held:
            flooredCounts.flooredResetsHeld += 1
            // Kotlin's own line (`InboundPipeline.kt:2899`), new here, so no harness pattern moves.
            log.log(.info, "mesh holding floored reset \(envelope.id) from \(sender) until our replacement floor ends")
        case .replaced(let previous):
            flooredCounts.flooredResetsHeld += 1
            flooredCounts.flooredResetsDropped += 1
            log.log(.info, "mesh dropped floored reset \(previous.envelope.id) from \(sender): its later reset \(envelope.id) replaced it")
            log.log(.info, "mesh holding floored reset \(envelope.id) from \(sender) until our replacement floor ends")
        case .older:
            log.log(.info, "mesh no hold for floored reset \(envelope.id) from \(sender): the reset held for it was sent later")
        }
    }

    /// Whether `open`'s failed frame is the follow-up of the reset we hold floored for its sender, at the root generation
    /// read before its open: it carries that reset's init (`explains`, `FlooredResets.kt:89-101`). A hold whose era moved
    /// is dropped here and explains nothing.
    func explainsByFlooredReset(_ open: DirectOpen) -> Bool {
        guard let eph = open.header.initial?.eph, let held = standingFlooredReset(of: open.sender, generation: open.generation) else {
            return false
        }
        return held.initEph == eph
    }

    /// `peer`'s held reset if it still stands at `generation`, else `nil`; one whose era moved is dropped, said and counted.
    private func standingFlooredReset(of peer: NodeId, generation: Int) -> FlooredResets.Held? {
        switch flooredResets.stand(peer, generation: generation) {
        case .absent:
            return nil
        case .stands(let held):
            return held
        case .dropped(let held):
            flooredCounts.flooredResetsDropped += 1
            log.log(.info, "mesh dropped floored reset \(held.envelope.id) from \(peer): the session's root moved since it was held")
            return nil
        }
    }

    /// Opens again every held reset whose peer's floor is open now (`dueFlooredResets` and `reopenFlooredResets`,
    /// `InboundPipeline.kt:2903-2915`, `MeshManager.kt:6165-6206`), the 60-second re-offer's second step, beside the reset
    /// re-seal's second pass and like it outside the link-set guards: due by the clock, from its own bytes. The floor is
    /// asked on the wall clock the open path stamps it with (``RatchetSessions/resetFloorOpen(for:now:)``). A hold whose era
    /// moved is dropped unrun. Each is taken out of the hold before it runs, verified again against the sender's pin, and
    /// handed to the chat door past the router's seen set, custody and the flood, as the first verdict of its original
    /// source, so its init is answered and an adoption runs every adoption's recovery: the purge, the re-seal, the forced
    /// seed flush and the answer that confirms the resetter. One that floors again holds again, after another adoption from
    /// that peer, so this runs at most once per floor. Adopted, the session anchored on the held init, the backlog follows.
    func reopenFlooredResets() {
        guard configuration.ratchet else {
            return
        }
        let now = clock.wallMilliseconds()
        for peer in flooredResets.peers {
            guard standingFlooredReset(of: peer, generation: ratchet.rootGeneration(of: peer)) != nil,
                ratchet.resetFloorOpen(for: peer, now: now), let held = flooredResets.take(peer)
            else {
                continue
            }
            reopen(held, from: peer)
        }
    }

    /// One held reset opened again (``reopenFlooredResets()``). The pin and then the session are read in units of their own,
    /// so a store that cannot answer never reads as a pin gone: a pin read that fails puts the hold back for the next
    /// re-offer. A session read that fails after the adoption committed skips the backlog, and nothing asks for it again:
    /// those DMs wait in our custody for the next start's replay. A hold the start's replay took opens as non-evidence
    /// (``FlooredResets/Held/mayBeEvidence``).
    private func reopen(_ held: FlooredResets.Held, from peer: NodeId) {
        let envelope = held.envelope
        let pin = stores.transactor.atomically { () -> PublicKeyBundle?? in .some(verifierBundle(for: envelope)) }
        guard case .committed(let bundle) = pin else {
            _ = flooredResets.hold(held, for: peer)
            log.log(.warning, "mesh kept floored reset \(envelope.id) from \(peer) for the next re-offer: a store failed")
            return
        }
        guard let bundle, bundle.nodeId == peer, bundle.isValidSignature(held.wire.sig, for: held.wire.signed) else {
            flooredCounts.flooredResetsDropped += 1
            log.log(.warning, "mesh dropped floored reset \(envelope.id) from \(peer): it no longer verifies against the pin")
            return
        }
        flooredCounts.flooredResetsReopened += 1
        // Kotlin's own line (`MeshManager.kt:6186`), new here, so no harness pattern moves.
        log.log(.info, "mesh re-opening floored reset \(envelope.id) from \(peer): our replacement floor ended")
        var route = RatchetInbound.Route(source: held.source, signed: true, origin: .firstVerdict, wire: held.wire)
        route.mayBeEvidence = held.mayBeEvidence
        handleChat(envelope, route: route)
        // swiftlint:disable:next discouraged_optional_boolean - a unit's body answers nil to abandon; this one never does
        let anchored = stores.transactor.atomically { () -> Bool? in ratchet.session(of: peer)?.peerInitEphPub == held.initEph }
        guard case .committed(true) = anchored else {
            // The hold was taken before `handleChat`, and the engine is synchronous, so any hold now is this frame again.
            let again = flooredResets.byPeer[peer] != nil
            let outcome = again ? "held again" : anchored == .committed(false) ? "not adopted" : "its session unread, a store failed"
            log.log(.info, "mesh re-opened floored reset \(envelope.id) from \(peer): \(outcome)")
            return
        }
        flooredCounts.flooredResetsAdopted += 1
        log.log(.info, "mesh re-opened floored reset \(envelope.id) from \(peer): adopted")
        replayFlooredResetBacklog(of: peer, initEph: held.initEph, except: envelope.id)
    }

    /// The re-open's backlog (`replayFlooredResetBacklog`, `MeshManager.kt:6208-6240`): `peer`'s ratchet DMs to us our own
    /// custody holds with no row, whose header carries the init `initEph`, but `except`, sealed under the reset while we held
    /// it and served again by nobody, our digest listing them. Selected by that ephemeral, never by a `sentAt` window, which
    /// would compare two clocks, and opened by the sender's own stamp, oldest first, so the chain walks forward. Each opens as
    /// a first verdict, so it is adopted and delivered as it would have been, but none is reset evidence: custody keeps a
    /// frame a spool served without saying so, and a spool's frame never is (``RatchetInbound/Route/mayBeEvidence``, ADR
    /// 2026-11.adrq), where Kotlin's are first verdicts in full. A frame that opened since stops at its row, read in a unit
    /// of its own, or drops as a duplicate.
    func replayFlooredResetBacklog(of peer: NodeId, initEph: [UInt8], except: String) {
        let me = ExactKey(nodeId.string)
        let (sender, skipped) = (ExactKey(peer.string), ExactKey(except))
        let frames = stores.custody.liveFrames(now: clock.wallMilliseconds()).reversed().filter { carried in
            let envelope = carried.envelope
            guard envelope.type == .chat, envelope.group == nil, envelope.recipientId.map(ExactKey.init) == me,
                ExactKey(envelope.senderId) == sender, ExactKey(envelope.id) != skipped,
                let enc = (try? ChatContent(decoding: envelope.payload))?.enc, RatchetInbound.isDirectRatchet(enc)
            else {
                return false
            }
            return enc.ratchet?.initial?.eph == initEph
        }
        // A stable order by the sender's stamp, ties left in custody's order.
        let ordered = frames.enumerated().sorted { ($0.element.envelope.sentAt, $0.offset) < ($1.element.envelope.sentAt, $1.offset) }
        for (_, carried) in ordered {
            let id = carried.envelope.id
            // The body answers the frame to open, or none once its row exists, never `nil`, which would abandon the unit.
            let unread = stores.transactor.atomically { () -> CarriedFrame?? in .some(stores.messages.contains(id) ? nil : carried) }
            switch unread {
            case .committed(let frame?):
                var route = RatchetInbound.Route(carried: frame, origin: .firstVerdict)
                route.mayBeEvidence = false
                handleChat(frame.envelope, route: route)
            case .committed(nil):
                continue
            case .joined, .abandoned, .failed:
                log.log(.warning, "mesh floored reset backlog \(id) from \(peer) skipped: a store failed")
            }
        }
    }
}
