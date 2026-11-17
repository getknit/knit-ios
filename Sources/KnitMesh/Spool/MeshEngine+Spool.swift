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
        /// First sight: carry, deliver, and bridge when this delivery newly carried it.
        case new
        /// Already seen, and custody does not hold it: carry and deliver, never bridge.
        case unheld
        /// Settled now.
        case settled(ScopeHeal.Settlement)
    }

    /// Verifies, delivers and settles one candidate `relay`'s heal loop raised, in one synchronous turn, in this order:
    /// 1. A profile over custody's profile cap is refused before anything reads it (``refusesOversizeProfile(type:id:signedCount:)``):
    ///    `.delivered(keptLive: false)`, so the heal accounts it, with nothing marked seen, pinned or bridged.
    /// 2. The signature, against ``verifierBundle(for:)``'s key (ours, a profile's own, the pinned one) read in a store unit
    ///    of its own, never through ``verify(_:)``: no key or a bad signature is `.unopenable`, with nothing marked seen, no
    ///    key request and nothing held in ``PendingInbound``; a unit that did not commit is `.notTaken`.
    /// 3. Whether custody held the frame before, read in a unit of its own; a failed read is `.notTaken`.
    /// 4. The carry gate (``isCarriable(_:)``) and ``Router/admitPulled(envelope:now:)``: no ingress budget, no overhear
    ///    (``pulledAdmission(_:heldBefore:)``). A copy the router already saw is carried and delivered when custody does not
    ///    hold it, and settles `.delivered(keptLive: true)` with nothing else done when it does.
    /// 5. Custody's carry, then delivery through the shared core with no link: a chat's route is ``RatchetInbound/Route/Source/spool``
    ///    and its hop `nil`. A custody write that failed is `.notTaken`, nothing delivered, and the router's mark taken back
    ///    when this turn made it (``Router/reopenPulled(_:)``).
    /// 6. `keptLive`, read in a unit of its own; a failed read is `.notTaken`, the mark taken back as above.
    /// 7. Every custody outcome, refusals included, is `.delivered(keptLive:)`.
    /// 8. The bridge, only for a first sight this delivery newly carried (not held before, custody changed, held after)
    ///    that is not late (``ScopeFrame/bridges``), and only while the engine's one bridge budget has a token
    ///    (``SpoolBridgeBudget``). Otherwise ``Router`` schedules nothing.
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
        guard let heldBefore = custodyHolds(id, now: wall) else {
            return .notTaken
        }
        let now = clock.monotonicMilliseconds()
        let admission = isCarriable(frame.envelope) ? router.admitPulled(envelope: frame.envelope, now: now) : nil
        if admission == .duplicate {
            spoolInbound.noteDuplicate()
        }
        let fresh: Bool
        switch Self.pulledAdmission(admission, heldBefore: heldBefore) {
        case .settled(let settled):
            return settled
        case .new:
            fresh = true
        case .unheld:
            fresh = false
        }
        let carry = custody.carrying(frame.carried, in: stores.custody, now: wall) { true }
        if carry.changed {
            noteCustodyChanged()
        }
        guard carry.stored?.refusal != CustodyRefusal.writeFailed, deliverPulled(frame), let keptLive = custodyHolds(id, now: wall) else {
            // Only an insert this turn made is taken back.
            if fresh {
                router.reopenPulled(id)
            }
            return .notTaken
        }
        let newlyCarried = fresh && !heldBefore && carry.changed && keptLive
        if newlyCarried, frame.bridges, router.relaysPulled(frame.wire), spoolInbound.takesBridgeToken(now: now) {
            _ = router.relayPulled(frame.wire, id: id, jitter: drawJitter(), now: now)
        }
        return .delivered(keptLive: keptLive)
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

    /// What the router's answer `admission` leaves the door to do, given whether custody held the frame before: a first
    /// sight is delivered; a copy already seen is carried and delivered when custody does not hold it, and settles kept
    /// when it does; and a refusal of the frame's own bytes (`nil` when the carry gate refused it, or an id not of its
    /// type's shape) is ``ScopeHeal/Settlement/refusedByCarry``, with nothing marked seen. The frame rule and the
    /// candidate's open make that last unreachable; it stays as defence.
    static func pulledAdmission(_ admission: Router.Admission?, heldBefore: Bool) -> PulledAdmission {
        switch admission {
        case .new:
            .new
        case .duplicate, .refused:
            heldBefore ? .settled(.delivered(keptLive: true)) : .unheld
        case .nonCanonical, nil:
            .settled(.refusedByCarry)
        }
    }

    /// The shared delivery core for a frame no link handed over: a profile as any is, and a chat along a spool's route, the
    /// one other type the frame rule admits into a DM scope. Answers `true`, so the door can chain it.
    private func deliverPulled(_ frame: ScopeFrame) -> Bool {
        if frame.envelope.type == .profile {
            handleProfile(frame.wire, frame.envelope)
        } else {
            handleChat(frame.envelope, route: RatchetInbound.Route(source: .spool, signed: true, origin: .firstVerdict))
        }
        return true
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
