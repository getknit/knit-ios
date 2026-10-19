public import KnitCrypto
import KnitWire

/// The session reset's pure rules, apart from the state that drives them (knit-next ADR 023, ADR 024, ADR 026 and ADR
/// 2026-09.qerd, at `ac491f4c`): which failures count as evidence, the era gate that keeps a stranded tail from counting,
/// the floors either side holds, and the plan a reset takes. ``RatchetSessions`` keeps the per-peer memory and applies
/// them: ``RatchetSessions/noteUndecryptable(from:frameId:sentAt:now:epochGoneBase:)`` runs ``isLiveEvidence(sentAt:session:now:)``
/// itself, on the session it reads in a unit, before a frame touches the heuristic's ids, and P5's inbound path checks
/// ``triggeringFailures`` before calling it.
public enum RatchetResetPolicy {
    /// Distinct undecryptable frames from one peer before a reset is due: one stuck frame, re-served endlessly by
    /// custody, must trigger nothing (`RESET_DISTINCT_FRAMES`, `RatchetSessions.kt:602`).
    public static let distinctFrames = 3
    /// The most frame ids remembered per peer for that count (`RESET_TRACKED_FRAMES`, `:605`).
    public static let trackedFrames = 8
    /// Our heuristic's floor per peer: six hours between resets (`RESET_MIN_INTERVAL_MS`, `:608`).
    public static let resetMilliseconds: Int64 = 21_600_000
    /// How long a tail sealed under an era we have left can still be re-served at us, custody's 24 h doubled; past it,
    /// an unreadable frame cannot be a remnant (`STRANDED_TAIL_MS`, `:620`, knit-next ADR 026).
    public static let strandedTailMilliseconds: Int64 = 172_800_000
    /// The receiver's floor on adopting another replacement from a peer: an hour (`REPLACEMENT_MIN_INTERVAL_MS`, `:623`).
    public static let replacementMilliseconds: Int64 = 3_600_000
    /// The same floor for an init flagged `FLAG_RESET`: a minute (`RESET_REPLACEMENT_MIN_INTERVAL_MS`, `:631`). Every
    /// build in the field holds both, so a reset sealed inside a peer's floor is refused there, silently.
    public static let resetReplacementMilliseconds: Int64 = 60_000

    /// The engine's failures that feed the heuristic (`RESET_TRIGGERING_DROPS`, `InboundPipeline.kt:3699-3704`):
    /// `NO_SESSION`, `EPOCH_GONE` and `AEAD_FAIL`, each from an authenticated frame. `BAD_HEADER` says nothing about our
    /// session, and `DUPLICATE` is proof we did open that index, so a re-served backlog of our own delivered history never
    /// counts (knit-next ADR 024). A throw out of the X3DH respond counts for nothing either.
    public static let triggeringFailures: Set<RatchetEngine.OpenOutcome.Failed> = [.noSession, .epochGone, .aeadFail]

    /// Whether an undecryptable frame sent at `sentAt` is evidence that `session`, the one we hold now, is broken, rather
    /// than ciphertext doomed before it arrived (`isLiveEvidence`, `InboundPipeline.kt:1892-1900`). A reset discards the
    /// keys its era sealed under, so a frame authored before the session's `establishedAt` is unreadable by construction,
    /// and counting its re-serves made each reset trip the peer's heuristic in turn (knit-next ADR 024).
    ///
    /// `sentAt` is the peer's clock, the envelope's signed stamp as it arrived and never clamped to ours (`env.sentAt`,
    /// `:1897-1899`). For a responder `establishedAt` is that peer's `init.at`, so the comparison is exact. For an
    /// initiator it is our clock: the skew bound absorbs ordinary disagreement, and once the era has outlived every
    /// retention window there is no stranded tail left anywhere, whatever the peer's clock says (knit-next ADR 026). A
    /// peer with no session passes, which ``RatchetSessions/noteUndecryptable(from:frameId:sentAt:now:epochGoneBase:)`` decides before
    /// calling.
    public static func isLiveEvidence(sentAt: Int64, session: RatchetEngine.SessionState, now: Int64) -> Bool {
        guard session.weAreInitiator else {
            return sentAt >= session.establishedAt
        }
        if now &- session.establishedAt >= strandedTailMilliseconds {
            return true
        }
        return sentAt >= session.establishedAt &- WireProtocol.maxFutureSkewMilliseconds
    }

    /// Whether an `EPOCH_GONE` whose header names our local epoch `pe` is doomed ciphertext rather than evidence that the
    /// session is broken (`isRetiredBase`, knit-next `RatchetSessions.kt:714-740` at `4f3cd995`, knit-next ADR 2026-10.9wvr):
    /// both must hold.
    ///
    /// - **`pe` is below `lowestRetained`**, the lowest epoch number we still hold for the peer. The key went to retention
    ///   and nothing brings it back; a reset strands the frame just the same. A `pe` at or above it that is missing (a
    ///   hole), or past our newest, is the split-era case the heuristic exists for, and still counts. The lowest number,
    ///   not the oldest mint: after our own reset restarts the numbering a dead era's high rows sit beside the live era's
    ///   low ones, and the minimum only drops, which narrows this rule.
    /// - **`pe` is below `highestPeAcked`**, the newest of our epochs the peer has sealed against that we opened under the
    ///   active root, recorded only on a fresh derivation (knit-next ADR 2026-09.pz9g). The peer's base for us only moves
    ///   forward within our numbering, so a frame on an older one is from its past, and the channel has worked since. A
    ///   peer still based on an epoch the 16-row cap evicted, one that never heard our newer ones, stays counted: there
    ///   `pe` equals its newest seal against us. Our own reset zeroes the ack with its fresh initiation, so the rule stays
    ///   shut until the peer seals under the new root.
    ///
    /// `pe = 0` is never retired: it names our signed prekey, whose retention is time-based, five kept a week apart, and a
    /// missing one may be a peer still pinned to a rotated prekey that will keep sealing inits we cannot open, which only a
    /// reset or our profile cures. Both numbers are this phone's own, our epoch counter echoed back, so no clock and no
    /// other device's counter enters.
    public static func isRetiredBase(pe: Int, highestPeAcked: Int, lowestRetained: Int) -> Bool {
        pe >= 1 && pe < lowestRetained && pe < highestPeAcked
    }

    /// Whether a frame from a peer whose init a session of ours anchored before a reinstall calls for our flagged reset now,
    /// given the session `held` (ADR 2026-10.wcex): while no session is held, or the one held is our own init the peer has
    /// not answered and no reset has gone since it. The frame proves the peer holds a session we lost, which three
    /// `NO_SESSION`s only suggest. In the first state ``plan(for:prekeyId:now:cause:)`` re-roots, and in the second it marks
    /// the init our frames ride (``Plan/Rule/plainInit``), whose flag exempts it from the peer's remnant guard
    /// (`RatchetEngine.kt:605-615` at `4f3cd995`), so the peer adopts it in either node-id order at its one-minute floor and re-seals its
    /// unacked DMs. A room tick sealed before the opener lands starts that plain init (`sealLiveTick`). The persisted
    /// `lastResetSentAt` is the loop guard: once our reset has gone, the next such frame sends nothing.
    public static func resetsOnAnsweredInit(_ held: RatchetEngine.SessionState?) -> Bool {
        guard let held else {
            return true
        }
        return held.weAreInitiator && !held.confirmed && held.lastResetSentAt < held.establishedAt
    }

    /// The floor an init with `flags` meets before it may replace a session we hold: a minute for `FLAG_RESET`, an hour
    /// otherwise (`RatchetSessions.kt:149-158`). The sender's six-hour floor is the real rate limit; the short one bounds
    /// what a peer that ignores it can cost us (knit-next ADR 023).
    public static func replacementFloor(flags: Int) -> Int64 {
        flags & RatchetHeader.resetFlag != 0 ? resetReplacementMilliseconds : replacementMilliseconds
    }

    /// The plan for a reset toward a peer we hold `session` with, whose pinned prekey is `prekeyId`, asked at `now` for
    /// `cause`; `answeredAt` is when the peer answered our own init, held in memory (`resetPlan`, `RatchetSessions.kt:392-422`,
    /// knit-next ADR 2026-09.qerd). A reset the peer would refuse is never sealed: one inside its floor is dropped as a
    /// duplicate after we have already left the root it is on, and our heuristic is then floored for six hours (#85, #86).
    ///
    /// The decline keys on the persisted `lastResetSentAt`, which survives a restart, never the stamp held in memory.
    public static func plan(
        for session: RatchetEngine.SessionState?,
        prekeyId: Int,
        now: Int64,
        cause: Cause,
        answeredAt: Int64?
    ) -> Plan {
        guard let session else {
            return Plan(action: .reRoot, decidedBy: .noSession)
        }
        let pendingInit = session.weAreInitiator && !session.confirmed
        // An init against a prekey the peer has since replaced may never be adoptable: only a fresh one heals it.
        if pendingInit, session.initPkid != prekeyId {
            return Plan(action: .reRoot, decidedBy: .initOnARetiredPrekey)
        }
        if cause == .afterWipe {
            let action: Plan.Action = session.lastResetSentAt > 0 ? .decline("a reset already went since the restore") : .mark
            return Plan(action: action, decidedBy: .afterWipe)
        }
        if pendingInit {
            // `initiate` stamps `establishedAt` with the `now` a reset stamps; a plain first seal leaves the stamp at 0.
            if session.lastResetSentAt < session.establishedAt {
                return Plan(action: .mark, decidedBy: .plainInit)
            }
            let inFlight = now &- session.lastResetSentAt < resetReplacementMilliseconds
            return Plan(action: inFlight ? .decline("our reset is still on its way") : .reRoot, decidedBy: .resetInFlight)
        }
        // The frames that failed prove the peer held another session with us, so taking our init was a replacement and
        // started its floor no later than it sealed its answer. An on-demand reset has no such evidence.
        guard cause == .unreadable, session.weAreInitiator, let answeredAt else {
            return Plan(action: .reRoot, decidedBy: .noPendingInit)
        }
        let insideFloor = now &- answeredAt < resetReplacementMilliseconds
        return Plan(action: insideFloor ? .decline("the peer adopted our init under a minute ago") : .reRoot, decidedBy: .answeredInit)
    }
}

extension RatchetResetPolicy {
    /// Why a reset is asked for: what the caller knows about the session it would replace (`ResetCause`,
    /// `RatchetSessions.kt:504-514`).
    public enum Cause: Sendable, Equatable {
        /// Asked for directly, by the control surface: nothing is known about the peer's state.
        case onDemand
        /// The heuristic: the peer's frames failed to open, so it held a session with us other than ours.
        case unreadable
        /// The first start after a restore whose ratchet tables came back empty: every session present was made since.
        case afterWipe
    }

    /// What a reset will do, and the rule that decided it: the field and floor the vectors' `decidedBy` names.
    public struct Plan: Sendable, Equatable {
        /// What the reset does (`ResetPlan`, `RatchetSessions.kt:494-502`).
        public enum Action: Sendable, Equatable {
            /// A fresh init flagged `FLAG_RESET`, our numbering restarted at 1, the old root kept draining.
            case reRoot
            /// The marker sealed under the session we hold, its header flagged while an init rides.
            case mark
            /// Nothing sealed: the peer would refuse a new root now, or already has the reset it needs.
            case decline(String)
        }

        /// Which rule decided the plan.
        public enum Rule: Sendable, Equatable {
            /// We hold no session.
            case noSession
            /// Our own init is pending against a prekey the peer has since replaced.
            case initOnARetiredPrekey
            /// The first start after a restore: the marker, once.
            case afterWipe
            /// Our own init is pending and plain: the peer may be adopting it from custody right now.
            case plainInit
            /// Our own init is pending and already a reset: declined inside the peer's minute, from its persisted stamp.
            case resetInFlight
            /// The heuristic's reset after the peer answered our init: declined inside the peer's minute from that answer.
            case answeredInit
            /// No pending init, and no answered-init floor applies.
            case noPendingInit
        }

        /// What the reset does.
        public let action: Action
        /// The rule that decided it.
        public let decidedBy: Rule
    }
}
