import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The reset's pure rules: the evidence that counts, the era gate, the floors and the plan (knit-next ADR 023, ADR 024,
/// ADR 026 and ADR 2026-09.qerd; `InboundPipeline.kt:1892-1900`, `:3699-3704`, `RatchetSessions.kt:392-422`, `:600-631`).
@Suite struct RatchetResetPolicyTests {
    static let now: Int64 = 1_700_000_000_000
    static let minute = RatchetResetPolicy.resetReplacementMilliseconds

    @Test func theFloorsAndBoundsAreAndroids() {
        #expect(RatchetResetPolicy.distinctFrames == 3)
        #expect(RatchetResetPolicy.trackedFrames == 8)
        #expect(RatchetResetPolicy.resetMilliseconds == 6 * 60 * 60_000)
        #expect(RatchetResetPolicy.strandedTailMilliseconds == 48 * 60 * 60_000)
        #expect(RatchetResetPolicy.replacementMilliseconds == 60 * 60_000)
        #expect(RatchetResetPolicy.resetReplacementMilliseconds == 60_000)
        #expect(RatchetResetPolicy.replacementFloor(flags: 0) == 60 * 60_000)
        #expect(RatchetResetPolicy.replacementFloor(flags: RatchetHeader.resetFlag) == 60_000)
        #expect(RatchetResetPolicy.replacementFloor(flags: 0b110) == 60 * 60_000, "only the reset bit shortens it")
    }

    /// Only an authenticated frame's `NO_SESSION`, `EPOCH_GONE` or `AEAD_FAIL` is evidence (knit-next ADR 024).
    @Test func duplicatesAndBadHeadersNeverCount() {
        #expect(RatchetResetPolicy.triggeringFailures == [.noSession, .epochGone, .aeadFail])
        #expect(!RatchetResetPolicy.triggeringFailures.contains(.duplicate))
        #expect(!RatchetResetPolicy.triggeringFailures.contains(.badHeader))
    }

    /// For a responder `establishedAt` is the peer's own `init.at`: one clock, compared exactly.
    @Test func aResponderComparesThePeersOwnClockExactly() {
        let held = session(weAreInitiator: false, establishedAt: Self.now)
        #expect(RatchetResetPolicy.isLiveEvidence(sentAt: Self.now, session: held, now: Self.now))
        #expect(!RatchetResetPolicy.isLiveEvidence(sentAt: Self.now - 1, session: held, now: Self.now + 100 * 60 * 60_000))
    }

    /// For an initiator `establishedAt` is our clock: five minutes of skew absorbed, and past 48 h every frame counts,
    /// whatever the peer's clock says (knit-next ADR 026).
    @Test func anInitiatorAbsorbsSkewAndCountsEverythingOnceTheTailIsGone() {
        let held = session(weAreInitiator: true, establishedAt: Self.now)
        let skew = WireProtocol.maxFutureSkewMilliseconds
        #expect(RatchetResetPolicy.isLiveEvidence(sentAt: Self.now - skew, session: held, now: Self.now))
        #expect(!RatchetResetPolicy.isLiveEvidence(sentAt: Self.now - skew - 1, session: held, now: Self.now))
        let tail = RatchetResetPolicy.strandedTailMilliseconds
        #expect(!RatchetResetPolicy.isLiveEvidence(sentAt: 0, session: held, now: Self.now + tail - 1))
        #expect(RatchetResetPolicy.isLiveEvidence(sentAt: 0, session: held, now: Self.now + tail))
    }

    @Test func withNoSessionAResetReRoots() {
        #expect(plan(nil) == .init(action: .reRoot, decidedBy: .noSession))
    }

    @Test func aPendingInitOnARetiredPrekeyReRootsWhateverTheCause() {
        let pending = session(weAreInitiator: true, confirmed: false, initPkid: 1)
        for cause in [RatchetResetPolicy.Cause.onDemand, .unreadable, .afterWipe] {
            #expect(plan(pending, prekeyId: 2, cause: cause) == .init(action: .reRoot, decidedBy: .initOnARetiredPrekey))
        }
    }

    @Test func afterAWipeTheMarkerGoesOnce() {
        let held = session(weAreInitiator: false)
        #expect(plan(held, cause: .afterWipe) == .init(action: .mark, decidedBy: .afterWipe))
        var marked = held
        marked.lastResetSentAt = 1
        #expect(plan(marked, cause: .afterWipe) == .init(action: .decline("a reset already went since the restore"), decidedBy: .afterWipe))
    }

    @Test func ourPlainPendingInitIsMarkedWhateverItsAge() {
        let pending = session(weAreInitiator: true, confirmed: false, establishedAt: Self.now - 30 * 24 * 60 * 60_000)
        #expect(plan(pending) == .init(action: .mark, decidedBy: .plainInit))
    }

    /// `initiate` stamps `establishedAt` with the `now` a reset stamps, so a pending reset is `lastResetSentAt ≥
    /// establishedAt`, and it re-roots only once the peer's minute is past, from the persisted stamp.
    @Test func ourPendingResetIsDeclinedForAMinuteFromItsPersistedStamp() {
        var pending = session(weAreInitiator: true, confirmed: false, establishedAt: Self.now)
        pending.lastResetSentAt = Self.now
        let inFlight = RatchetResetPolicy.Plan(action: .decline("our reset is still on its way"), decidedBy: .resetInFlight)
        #expect(plan(pending, now: Self.now + Self.minute - 1) == inFlight)
        #expect(plan(pending, now: Self.now + Self.minute) == .init(action: .reRoot, decidedBy: .resetInFlight))
    }

    @Test func theHeuristicsResetWaitsAMinuteFromOurInitsAnswer() {
        let held = session(weAreInitiator: true)
        let declined = RatchetResetPolicy.Plan(action: .decline("the peer adopted our init under a minute ago"), decidedBy: .answeredInit)
        #expect(plan(held, cause: .unreadable, answeredAt: Self.now - Self.minute + 1) == declined)
        #expect(plan(held, cause: .unreadable, answeredAt: Self.now - Self.minute) == .init(action: .reRoot, decidedBy: .answeredInit))
    }

    /// The answered-init floor needs evidence that the peer held another session: the heuristic's, for an init of ours.
    @Test func anOnDemandResetOrAResponderMeetsNoAnsweredInitFloor() {
        let noFloor = RatchetResetPolicy.Plan(action: .reRoot, decidedBy: .noPendingInit)
        #expect(plan(session(weAreInitiator: true), cause: .onDemand, answeredAt: Self.now) == noFloor)
        #expect(plan(session(weAreInitiator: false), cause: .unreadable, answeredAt: Self.now) == noFloor)
        #expect(plan(session(weAreInitiator: true), cause: .unreadable, answeredAt: nil) == noFloor, "a restart forgot the answer")
    }

    private func plan(
        _ held: RatchetEngine.SessionState?,
        prekeyId: Int = 1,
        now: Int64 = Self.now,
        cause: RatchetResetPolicy.Cause = .onDemand,
        answeredAt: Int64? = nil
    ) -> RatchetResetPolicy.Plan {
        RatchetResetPolicy.plan(for: held, prekeyId: prekeyId, now: now, cause: cause, answeredAt: answeredAt)
    }

    private func session(
        weAreInitiator: Bool,
        confirmed: Bool = true,
        establishedAt: Int64 = Self.now - 1000,
        initPkid: Int = 1
    ) -> RatchetEngine.SessionState {
        RatchetEngine.SessionState(
            peerId: fixtureNodeId(2),
            confirmed: confirmed,
            weAreInitiator: weAreInitiator,
            root: [UInt8](repeating: 1, count: 32),
            establishedAt: establishedAt,
            initPkid: initPkid
        )
    }
}
