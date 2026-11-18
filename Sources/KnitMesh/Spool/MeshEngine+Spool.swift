import KnitCrypto
import KnitStore
import KnitWire

/// The spool's door into the engine (ADR 2026-11.adrq, P4a): a candidate a heal loop opened becomes a frame, is delivered
/// with no link, and is settled in the same turn. Kotlin hands a pulled frame to `MeshRouter.handleInbound` under the
/// source `"spool:<url>"` (`ScopeSync.kt:3026-3047`, `MeshManager.kt:1185` at knit-next `0832b8462`); this port keeps
/// ``InboundFrame`` link-only, so no transport can build a spool-sourced frame, and this is the one door.
extension MeshEngine {
    /// What the router's answer leaves the door to do.
    enum PulledAdmission: Equatable {
        /// First sight: carry, deliver, and bridge when this delivery newly carried it and it delivered.
        case new
        /// Already seen, and custody does not hold it: carry and deliver, never bridge.
        case unheld
        /// An id the radios let past for a re-seal, under bytes custody does not hold: carry and open it once, unmarked, and
        /// mark and bridge it as a first sight only once it delivered.
        case reopened
        /// Settled now.
        case settled(ScopeHeal.Settlement)
    }

    /// What custody held under a candidate's id before the door carried it.
    enum HeldCopy: Equatable {
        /// Nothing live.
        case absent
        /// A live frame, by its signed bytes.
        case held(signed: [UInt8])
    }

    /// Verifies, delivers and settles one candidate `relay`'s heal loop raised, in one synchronous turn, in this order:
    /// 1. A profile over custody's profile cap is refused before anything reads it (``refusesOversizeProfile(type:id:signedCount:)``):
    ///    `.delivered(keptLive: false)`, so the heal accounts it, with nothing marked seen, pinned or bridged.
    /// 2. The signature, against ``verifierBundle(for:)``'s key (ours, a profile's own, the pinned one) read in a store unit
    ///    of its own, never through ``verify(_:)``: no key or a bad signature is `.unopenable`, with nothing marked seen, no
    ///    key request and nothing held in ``PendingInbound``; a unit that did not commit is `.notTaken`.
    /// 3. What custody held under the id before, read in a unit of its own; a failed read is `.notTaken`.
    /// 4. The carry gate (``isCarriable(_:)``) and ``Router/admitPulled(envelope:now:)``: no ingress budget, no overhear
    ///    (``pulledAdmission(_:held:served:)``). A copy the router already saw is carried and delivered when custody does not
    ///    hold it, and settles `.delivered(keptLive: true)` with nothing else done when it does. A copy under an id the
    ///    radios let past for a re-seal settles the same way when custody holds its very bytes, and is otherwise opened once,
    ///    unmarked.
    /// 5. Custody's carry, then delivery through the shared core with no link: a chat's route is ``RatchetInbound/Route/Source/spool``
    ///    and its hop `nil`. A custody write that failed is `.notTaken`, nothing delivered, and the router's mark taken back
    ///    when this turn made it (``Router/reopenPulled(_:)``).
    /// 6. `keptLive`, read in a unit of its own; a failed read is `.notTaken`, the mark taken back as above.
    /// 7. The mark, once the copy delivered or failed: a ratchet open refused with a typed failure, or left for the replay
    ///    (``SpoolInbound/takeUndelivered(_:)``), takes back this turn's mark when custody held the id before, a copy this
    ///    node had already judged, so the bytes that failed never stop the re-seal under that id. A first sight keeps it,
    ///    so the radio's copy of the same bytes is a duplicate, never a second counted failure. A reopened copy that
    ///    delivered is marked now.
    /// 8. Every custody outcome, refusals included, is `.delivered(keptLive:)`.
    /// 9. The bridge, only for a first sight, or a reopened copy, that delivered and that this delivery newly carried (not
    ///    held before, custody changed, held after) and that is not late (``ScopeFrame/bridges``), and only while the
    ///    engine's one bridge budget has a token (``SpoolBridgeBudget``). Otherwise ``Router`` schedules nothing.
    ///
    /// No presence is recorded from a spool frame, and nothing link-only (a key request, the blob controls, a hand-on) is
    /// reachable from here: the frame rule admits a DM-form chat and a profile alone.
    /// Its lines say `spool` and name neither the relay nor the scope (P4b1).
    func receiveFromSpool(_ candidate: ScopeCandidate, relay _: SpoolRelayHandle) -> ScopeHeal.Settlement {
        let settlement = spoolSettlement(candidate)
        spoolInbound.note(settlement)
        return settlement
    }

    private func spoolSettlement(_ candidate: ScopeCandidate) -> ScopeHeal.Settlement {
        let id = candidate.frameId
        guard !refusesOversizeProfile(type: candidate.claimedType, id: id, signedCount: candidate.signedByteCount) else {
            spoolInbound.noteOversizeProfile()
            return .delivered(keptLive: false)
        }
        guard let verified = verifiedInUnit(candidate) else {
            return .notTaken
        }
        guard let frame = verified else {
            log.log(.debug, "spool unopenable \(id.prefix(CustodySync.idCharacters)): no key or a bad signature")
            return .unopenable
        }
        let wall = clock.wallMilliseconds()
        guard let held = custodyCopy(id, now: wall) else {
            return .notTaken
        }
        let heldBefore = held != .absent
        let now = clock.monotonicMilliseconds()
        let admission = isCarriable(frame.envelope) ? router.admitPulled(envelope: frame.envelope, now: now) : nil
        if admission == .duplicate {
            spoolInbound.noteDuplicate()
        }
        let pulled = Self.pulledAdmission(admission, held: held, served: frame.wire.signed)
        if case .settled(let settled) = pulled {
            return settled
        }
        // `fresh`: this turn's admission marked the id. `firstSight`: it may be marked and bridged once it delivers.
        let fresh = pulled == .new
        let firstSight = fresh || pulled == .reopened
        let carry = custody.carrying(frame.carried, in: stores.custody, now: wall) { true }
        if carry.changed {
            noteCustodyChanged()
        }
        guard carry.stored?.refusal != CustodyRefusal.writeFailed, case let delivered = deliverPulled(frame),
            let keptLive = custodyHolds(id, now: wall)
        else {
            // Only an insert this turn made is taken back.
            if fresh {
                router.reopenPulled(id)
            }
            return .notTaken
        }
        settleMark(frame, pulled, delivered: delivered, heldBefore: heldBefore, now: now)
        let newlyCarried = firstSight && delivered && !heldBefore && carry.changed && keptLive
        if newlyCarried, frame.bridges, router.relaysPulled(frame.wire), spoolInbound.takesBridgeToken(now: now) {
            _ = router.relayPulled(frame.wire, id: id, jitter: drawJitter(), now: now)
        }
        return .delivered(keptLive: keptLive)
    }

    /// Step 7: a mark this turn made for a copy that delivered nothing, under an id custody held before, is taken back; a
    /// reopened copy that delivered is marked now. Everything else keeps what the admission left.
    private func settleMark(_ frame: ScopeFrame, _ pulled: PulledAdmission, delivered: Bool, heldBefore: Bool, now: Int64) {
        if pulled == .new, !delivered, heldBefore {
            router.reopenPulled(frame.envelope.id)
        } else if pulled == .reopened, delivered {
            router.markPulled(frame.envelope.id, now: now)
        }
    }

    /// Tells the spool's door that `envelope`, along `route`, delivered nothing: a typed failure, or a unit left for the
    /// replay, as the ratchet's inbound path reports it. The door then neither bridges it nor leaves
    /// it a mark, unless it was this node's first sight of the id (``settleMark(_:_:delivered:heldBefore:now:)``,
    /// ADR 2026-11.adrq, P7 prep). A frame off a link is no concern of the door's.
    func noteSpoolUndelivered(_ envelope: RelayEnvelope, route: RatchetInbound.Route) {
        if route.isSpool {
            spoolInbound.noteUndelivered(envelope.id)
        }
    }

    /// The candidate's frame once its signature verifies against ``verifierBundle(for:)``'s key, read in a store unit of its
    /// own: `.some(nil)` for no key or a bad signature, and `nil` when the unit did not commit.
    private func verifiedInUnit(_ candidate: ScopeCandidate) -> ScopeFrame?? {
        var committed = true
        let frame = candidate.verified { envelope in
            let read = stores.transactor.atomically { () -> PublicKeyBundle?? in .some(verifierBundle(for: envelope)) }
            guard case .committed(let bundle) = read else {
                committed = false
                return nil
            }
            return bundle
        }
        return committed ? .some(frame) : nil
    }

    /// What the router's answer `admission` leaves the door to do, given what custody `held` under the id before and the
    /// candidate's `served` signed bytes: a first sight is delivered; a copy already seen is carried and delivered when
    /// custody does not hold it, and settles kept when it does; a copy under an id the radios reopened settles kept when
    /// custody holds those very bytes, which this node already judged, and is opened once otherwise; and a refusal of the
    /// frame's own bytes (`nil` when the carry gate refused it, or an id not of its type's shape) is
    /// ``ScopeHeal/Settlement/refusedByCarry``, with nothing marked seen. The frame rule and the candidate's open make that
    /// last unreachable; it stays as defence.
    static func pulledAdmission(_ admission: Router.Admission?, held: HeldCopy, served: [UInt8]) -> PulledAdmission {
        switch admission {
        case .new:
            .new
        case .duplicate, .refused:
            held == .absent ? .unheld : .settled(.delivered(keptLive: true))
        case .reopened:
            held == .held(signed: served) ? .settled(.delivered(keptLive: true)) : .reopened
        case .nonCanonical, nil:
            .settled(.refusedByCarry)
        }
    }

    /// The shared delivery core for a frame no link handed over: a profile as any is, and a chat along a spool's route, the
    /// one other type the frame rule admits into a DM scope. Answers whether it delivered: `false` when its ratchet open
    /// was refused with a typed failure or left for the replay (``SpoolInbound/takeUndelivered(_:)``).
    private func deliverPulled(_ frame: ScopeFrame) -> Bool {
        spoolInbound.beginDelivery()
        if frame.envelope.type == .profile {
            handleProfile(frame.wire, frame.envelope)
        } else {
            handleChat(frame.envelope, route: RatchetInbound.Route(source: .spool, signed: true, origin: .firstVerdict))
        }
        return !spoolInbound.takeUndelivered(frame.envelope.id)
    }

    /// What custody holds under `id` live at `now`, read in a store unit of its own; `nil` when the unit failed, which a SQL
    /// store would otherwise answer as "not held" (ADR 2026-09.nyya).
    func custodyCopy(_ id: String, now: Int64) -> HeldCopy? {
        let read = stores.transactor.atomically { () -> HeldCopy? in
            stores.custody.frame(id, now: now).map { .held(signed: $0.signed) } ?? HeldCopy.absent
        }
        guard case .committed(let held) = read else {
            return nil
        }
        return held
    }

    /// Whether custody holds `id` live at `now`, read in a store unit of its own, never nested in another; `nil` when the
    /// unit failed, which a SQL store would otherwise answer as "not held" (ADR 2026-09.nyya).
    func custodyHolds(_ id: String, now: Int64) -> Bool? { // swiftlint:disable:this discouraged_optional_boolean
        // `nil` is the failed unit, which must never read as "not held".
        // swiftlint:disable:next discouraged_optional_boolean - a unit's body answers nil to abandon; this one never does
        let read = stores.transactor.atomically { () -> Bool? in stores.custody.frame(id, now: now) != nil }
        guard case .committed(let held) = read else {
            return nil
        }
        return held
    }
}
