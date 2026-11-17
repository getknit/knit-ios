import KnitCrypto
import KnitWire

/// A blob the spool sent, from its claim to its settlement (`accept`, `refuse`, `quarantine` and `account`,
/// `ScopeSync.kt:2996-3049`, `:3145-3228`).
extension ScopeHeal {
    /// A pulled or live blob: claimed on the connection before anything else (`accept`, `:3004-3008`), so a pull and an
    /// `event` racing for one blob deliver it once, then hashed, opened and held to the rule. One that fails is released,
    /// and quarantined only when we pulled it (C-9.3-1, C-9.3-4); one that passes goes to the caller as a candidate, its
    /// claim held until it is settled. A blob for a scope the table no longer carries is not claimed at all.
    ///
    /// A live `event` naming an id this scope already accounted or quarantined is dropped before it is claimed. A pulled
    /// arrival past the pull's reserved worst case is charged to the hour at once. Only a bad content address counts
    /// against the relay (``SpoolIntake``).
    mutating func accept(
        _ arrival: SpoolArrival, _ source: ScopeCandidate.Source, request: Int64?, session: inout SpoolSession, now: SpoolNow
    ) {
        guard let scope = scopesById[arrival.scope], let state = states[arrival.scope] else {
            return
        }
        if source == .live, state.accounted.contains(arrival.blobId) || state.invalid.contains(arrival.blobId) {
            counts.replays += 1
            return
        }
        if source == .pulled, let request, case .pulling(request)? = step?.phase, let current = step, current.scope.id == scope.id {
            let received = current.pullReceived + arrival.data.count
            intake.charge(bytes: max(0, received - max(current.pullReceived, current.pullReserved)), now: now.monotonic)
            step?.pullReceived = received
        }
        guard session.claim(scope.id, blobId: arrival.blobId) else {
            counts.duplicates += 1
            return
        }
        let addressed = ScopeCrypto.blobId(of: arrival.data) == arrival.blobId.bytes
        let candidate = addressed ? ScopeFrames.open(arrival, in: scope, me: me, source: source, now: now.wall) : nil
        if candidate == nil {
            session.release(scope.id, blobId: arrival.blobId)
            if source == .pulled {
                quarantine(arrival.blobId, in: scope.id)
            }
        }
        if source == .pulled {
            judge(spoolFault: !addressed, session: &session, now: now)
        }
        if let candidate {
            outbox.append(.candidate(candidate))
        }
    }

    /// The caller's turn with a candidate is over. Every claim ends here, released or settled, on every outcome:
    /// - ``Settlement/unopenable`` or ``Settlement/refusedByCarry``, a refusal of the frame's own bytes: released, and
    ///   quarantined when it was pulled (`refuse`, `:3145-3152`). It is not counted against the relay: anyone who knows the
    ///   scope could have pushed it, or the spool minted it, and the hourly budget bounds what such blobs cost.
    /// - ``Settlement/notTaken``: released, nothing more, so a later round may pull it again.
    /// - delivered: the claim is kept and the connection's set trimmed (`settle`), the blob leaves the unpushable set, and
    ///   it is accounted when custody did not keep it live or it was late (C-9.6-1). Asking custody rather than
    ///   re-deriving its rule is Kotlin's choice (`:3042-3047`): its TTL and quotas decide, and a second copy here would
    ///   drift. The scope looks again.
    mutating func settle(_ candidate: ScopeCandidate, _ outcome: Settlement, session: inout SpoolSession, now _: SpoolNow) {
        switch outcome {
        case .unopenable, .refusedByCarry:
            session.release(candidate.scope, blobId: candidate.blobId)
            if candidate.source == .pulled {
                quarantine(candidate.blobId, in: candidate.scope)
            }
        case .notTaken:
            session.release(candidate.scope, blobId: candidate.blobId)
        case .delivered(let keptLive):
            session.settle(candidate.scope)
            if candidate.isLate || !keptLive {
                account(candidate.blobId, in: candidate.scope)
            }
            // A verified blob the spool served is one it holds: a held frame left unpushable goes back into the fold, so
            // the next round lists and the anchor learns it.
            if states[candidate.scope]?.unpushable.remove(candidate.blobId) == true {
                states[candidate.scope]?.stickyUnpushable.remove(candidate.blobId)
            }
            markDirty(candidate.scope)
        }
    }

    /// A pulled blob served past our `maxBlob`: its bytes are charged to the hour, and it is the spool's fault alone.
    mutating func servedOversize(bytes: Int, session: inout SpoolSession, now: SpoolNow) {
        intake.charge(bytes: bytes, now: now.monotonic)
        judge(spoolFault: true, session: &session, now: now)
    }

    /// Counts a pulled blob for or against the relay, and ends the session at the `unopenable` fault (``SpoolIntake``).
    /// What arrives after the session ended is charged and never judged: the fault was already found.
    mutating func judge(spoolFault: Bool, session: inout SpoolSession, now: SpoolNow) {
        if session.isReady, intake.judged(spoolFault: spoolFault, now: now.monotonic) {
            counts.faults += 1
            session.end(.unopenable)
        }
    }

    /// Puts a pulled blob that failed into the scope's invalid set, never to be pulled again (§9.3).
    mutating func quarantine(_ blobId: SpoolID, in scope: SpoolID) {
        if states[scope]?.invalid.insert(blobId) == true {
            counts.quarantined += 1
        }
    }

    /// Accounts a delivered blob custody did not keep (§9.6): folded in as if held, and never pulled again.
    mutating func account(_ blobId: SpoolID, in scope: SpoolID) {
        if states[scope]?.accounted.insert(blobId) == true {
            counts.accounted += 1
        }
    }
}
