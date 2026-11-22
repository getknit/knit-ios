import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The facade's half of knit-next ADR 2026-11.sfms and the 2026-11-01 amendment to its ADR 2026-09.qerd (#251; ADR
/// 2026-10.5sk9's P9b amendment), after `RatchetSessionsResetTest`'s #251 cases at `f018bc8ce`: the sender's `replacedAt`,
/// stamped when the peer took an init of ours as a replacement and cleared only by a forget, which declines every cause but
/// after-wipe for a minute; the per-peer root generation a floored reset's hold reads; and the floor its re-open asks. Two
/// real facades over memory stores.
@Suite struct RatchetSessionsReplacedTests {
    static let t0: Int64 = 100_000_000
    static let minute = RatchetResetPolicy.resetReplacementMilliseconds
    static let replaced = "the peer adopted our reset under a minute ago"

    /// A first contact, `us` initiating and `them` answering: confirmed, and no replacement anywhere.
    private func firstContact() throws -> (us: RatchetSessionSide, them: RatchetSessionSide) {
        let (us, them) = try RatchetSessionSide.pair()
        #expect(plaintext(try them.open(us.seal("hello", now: Self.t0), now: Self.t0, sentAt: Self.t0)) != nil)
        #expect(plaintext(try us.open(them.seal("hi", now: Self.t0 + 1), now: Self.t0 + 1, sentAt: Self.t0 + 1)) != nil)
        #expect(us.session?.confirmed == true)
        return (us, them)
    }

    /// Our reset, adopted by the peer, and its answer committed here at `answeredAt`: a replacement answered
    /// (`aSecondForcedResetRightAfterTheFirstWasAnsweredIsDeclined`, `SessionLabTest`).
    private func resetAnswered(at answeredAt: Int64) throws -> (us: RatchetSessionSide, them: RatchetSessionSide) {
        let (us, them) = try firstContact()
        let reset = try sealedReset(us.reset(now: answeredAt - 2))
        #expect(reset.reRooted)
        #expect(plaintext(try them.open(reset.envelope, now: answeredAt - 1, sentAt: answeredAt - 2)) != nil)
        #expect(plaintext(try us.open(them.seal("answer", now: answeredAt), now: answeredAt, sentAt: answeredAt)) != nil)
        #expect(us.session?.confirmed == true && us.session?.weAreInitiator == true)
        return (us, them)
    }

    /// An answered reset of ours declines a forced reset inside the peer's minute, which before the amendment re-rooted
    /// into the peer's floor, and re-roots at the minute. The heuristic's own rule keeps its reason; after-wipe keeps its.
    @Test func everyCauseButAfterWipeIsDeclinedInsideTheMinuteAfterOurResetWasAnswered() throws {
        let answeredAt = Self.t0 + 10_000
        let (us, _) = try resetAnswered(at: answeredAt)
        guard case .declined(let reason, let plan) = try us.reset(now: answeredAt + 30_000, cause: .onDemand) else {
            Issue.record("a forced reset inside the peer's minute went out")
            return
        }
        #expect(reason == Self.replaced && plan.decidedBy == .replacedInit)
        guard case .declined(let heuristic, _) = try us.reset(now: answeredAt + 30_000, cause: .unreadable) else {
            Issue.record("a heuristic reset inside the peer's minute went out")
            return
        }
        #expect(heuristic == "the peer adopted our init under a minute ago", "the heuristic's rule decides first")
        guard case .declined(_, let wiped) = try us.reset(now: answeredAt + 30_000, cause: .afterWipe) else {
            Issue.record("expected after-wipe's own decline: a reset already went")
            return
        }
        #expect(wiped.decidedBy == .afterWipe, "after-wipe is never the replacement floor's")
        #expect(try sealedReset(us.reset(now: answeredAt + Self.minute, cause: .onDemand)).reRooted, "the minute is up")
    }

    /// A first contact the peer established started no floor: a forced reset right after it goes out
    /// (`anOnDemandResetRightAfterFirstContactGoesOut`).
    @Test func aFirstContactStampsNoReplacement() throws {
        let (us, _) = try firstContact()
        #expect(try sealedReset(us.reset(now: Self.t0 + 2, cause: .onDemand)).reRooted)
    }

    /// A race we won, having resolved the peer's own init, is a replacement too: the peer resolves it by adopting ours and
    /// purging, so its answer starts the peer's floor (`peerReplacedWith`'s second half).
    @Test func aRaceWeWonIsAReplacementAnswered() throws {
        let (one, two) = try RatchetSessionSide.pair()
        let (winner, loser) = one.nodeId < two.nodeId ? (one, two) : (two, one)
        let winnersOpener = try winner.seal("winner opens", now: Self.t0)
        #expect(plaintext(try winner.open(loser.seal("loser opens", now: Self.t0), now: Self.t0, sentAt: Self.t0)) != nil)
        #expect(winner.session?.peerInitEphPub != nil && winner.session?.confirmed == false, "the winner resolved the loser's init")
        #expect(plaintext(try loser.open(winnersOpener, now: Self.t0 + 1, sentAt: Self.t0)) != nil)
        #expect(plaintext(try winner.open(loser.seal("answer", now: Self.t0 + 2), now: Self.t0 + 2, sentAt: Self.t0 + 2)) != nil)
        #expect(winner.session?.confirmed == true)
        #expect(winner.sessions.rootGeneration(of: loser.nodeId) == 0, "a race won moves no root")
        #expect(loser.sessions.rootGeneration(of: winner.nodeId) == 1, "a race lost does")
        guard case .declined(let reason, _) = try winner.reset(now: Self.t0 + 30_000, cause: .onDemand) else {
            Issue.record("a forced reset inside the loser's minute went out")
            return
        }
        #expect(reason == Self.replaced)
    }

    /// `replacedAt` outlives our own re-root, which Kotlin's `reRoot` leaves alone, and goes only with a forget: a session the
    /// peer starts afresh after it is free of the old stamp.
    @Test func replacedAtIsClearedByAForgetAlone() throws {
        let answeredAt = Self.t0 + 10_000
        let (us, them) = try resetAnswered(at: answeredAt)
        us.sessions.settle(.reset(to: them.nodeId, at: answeredAt + 1, reRooted: true))
        #expect(isDeclined(try us.reset(now: answeredAt + 2, cause: .onDemand)), "a re-root keeps it")

        us.wipe()
        them.wipe()
        #expect(plaintext(try us.open(them.seal("again", now: answeredAt + 3), now: answeredAt + 3, sentAt: answeredAt + 3)) != nil)
        #expect(us.session?.weAreInitiator == false, "the peer started afresh")
        #expect(try sealedReset(us.reset(now: answeredAt + 4, cause: .onDemand)).reRooted, "the forget took the stamp")
    }

    /// The root generation moves at Kotlin's sites alone, per peer: a replacement adopted, our own re-root, a forget. Not a
    /// session first established, nor a marker, nor our init answered.
    @Test func theRootGenerationMovesAtARootChangeAlone() throws {
        let (us, them) = try RatchetSessionSide.pair()
        #expect(plaintext(try them.open(us.seal("hello", now: Self.t0), now: Self.t0, sentAt: Self.t0)) != nil)
        #expect(them.sessions.rootGeneration(of: us.nodeId) == 0, "established")
        let marked = try us.reset(now: Self.t0 + 1)
        guard case .sealed(let marker, let plan) = marked, plan.action == .mark else {
            Issue.record("expected the marker over our plain init, got \(marked)")
            return
        }
        #expect(us.sessions.rootGeneration(of: them.nodeId) == 0, "a marker moves no root")
        #expect(plaintext(try them.open(marker, now: Self.t0 + 2, sentAt: Self.t0 + 1)) != nil)
        #expect(them.sessions.rootGeneration(of: us.nodeId) == 0, "resolved by its ephemeral")
        #expect(plaintext(try us.open(them.seal("hi", now: Self.t0 + 3), now: Self.t0 + 3, sentAt: Self.t0 + 3)) != nil)
        #expect(us.session?.confirmed == true && us.sessions.rootGeneration(of: them.nodeId) == 0, "our init answered")

        let reset = try sealedReset(them.reset(now: Self.t0 + 4))
        #expect(them.sessions.rootGeneration(of: us.nodeId) == 1, "our own re-root")
        #expect(plaintext(try us.open(reset.envelope, now: Self.t0 + 5, sentAt: Self.t0 + 4)) != nil)
        #expect(us.sessions.rootGeneration(of: them.nodeId) == 1, "a replacement adopted")
        #expect(us.sessions.rootGeneration(of: fixtureNodeId(9)) == 0, "per peer")
        us.wipe()
        #expect(us.sessions.rootGeneration(of: them.nodeId) == 2, "a forget")
    }

    /// The floor the re-open asks, on the open path's wall clock: shut a millisecond inside the minute after an adoption.
    @Test func theResetFloorOpensAMinuteAfterAnAdoption() throws {
        let (us, them) = try firstContact()
        #expect(them.sessions.resetFloorOpen(for: us.nodeId, now: Self.t0), "nothing adopted yet")
        let reset = try sealedReset(us.reset(now: Self.t0 + 10))
        #expect(plaintext(try them.open(reset.envelope, now: Self.t0 + 20, sentAt: Self.t0 + 10)) != nil)
        #expect(!them.sessions.resetFloorOpen(for: us.nodeId, now: Self.t0 + 20 + Self.minute - 1))
        #expect(them.sessions.resetFloorOpen(for: us.nodeId, now: Self.t0 + 20 + Self.minute))
    }
}
