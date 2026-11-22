import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The race loser's reclaim through the facade (knit-next ADR 2026-10.4mjm; ADR 2026-10.5sk9's P9a amendment), after
/// knit-next's `RatchetSessionsReclaimTest` at `f018bc8ce`: the freshness judged on the envelope's own stamp, the floors a
/// reclaim moves, the answer floor it stamps (the design pass's blocking finding), the start's replay, and the pure rules.
/// Two real facades over memory stores; every envelope is opened with the stamp it was sealed at.
@Suite struct RatchetSessionsReclaimTests {
    static let t0: Int64 = 100_000_000
    static let skew = WireProtocol.maxFutureSkewMilliseconds

    /// The loser, the larger id, lost the race at `t0 + 1000` to the winner's init; the winner then lost its rows and
    /// established from the loser's opener as its responder, the loser's lost init.
    private func lostAndAnswered(log: any KnitLog = SilentLog()) throws -> (winner: RatchetSessionSide, loser: RatchetSessionSide) {
        let (one, two) = try RatchetSessionSide.pair(log: log)
        let (winner, loser) = one.nodeId < two.nodeId ? (one, two) : (two, one)
        let opener = try loser.seal("loser opens", now: Self.t0)
        #expect(
            plaintext(try loser.open(winner.seal("winner opens", now: Self.t0 + 1000), now: Self.t0 + 1000, sentAt: Self.t0 + 1000)) != nil)
        let lost = try #require(loser.session)
        #expect(lost.prevRootOwnInitAt == Self.t0 && lost.establishedAt == Self.t0 + 1000, "the loser stamped its own init")
        winner.wipe()
        #expect(plaintext(try winner.open(opener, now: Self.t0 + 2000, sentAt: Self.t0)) != nil)
        return (winner, loser)
    }

    /// The trace: the winner's answer, sealed past the margin, moves the loser back onto its init, and the reclaim moves
    /// every floor a root change moves, the answer floor among them: the peer adopted our init no later than it sealed the
    /// frame, so our heuristic's re-root inside the peer's minute is declined, as after any answer (`commitOpen`, knit-next
    /// `RatchetSessions.kt:300-306`). Without that stamp a race loser, a confirmed responder, never reads as answered.
    @Test func aReclaimMovesTheFloorsOfARootChangeAndStampsTheAnswerFloor() throws {
        let log = RecordingLog()
        let (winner, loser) = try lostAndAnswered(log: log)
        _ = loser.sessions.noteUndecryptable(from: winner.nodeId, frameId: "stray", sentAt: Self.t0 + 1500, now: Self.t0 + 1500)
        let generation = loser.sessions.generation
        let at = Self.t0 + 1000 + Self.skew + 1
        #expect(plaintext(try loser.open(winner.seal("under your init", now: at), now: at, sentAt: at)) != nil)
        let reclaimed = try #require(loser.session)
        #expect(reclaimed.root == winner.session?.root && reclaimed.confirmed && reclaimed.weAreInitiator)
        let floors = loser.sessions.floors(for: winner.nodeId)
        #expect(floors.confirmedAt == at && floors.lastReplacementAt == at && floors.undecryptableIds == 0)
        #expect(loser.sessions.generation == generation + 1, "the scopes moved")
        #expect(loser.sessions.reclaims == 1)
        #expect(log.all.contains { $0.contains("reclaimed our own init with \(winner.nodeId)") })

        guard case .declined(let reason, _) = try loser.reset(now: at + 30_000, cause: .unreadable) else {
            Issue.record("a heuristic re-root inside the peer's minute went out")
            return
        }
        #expect(reason == "the peer adopted our init under a minute ago")
        #expect(try sealedReset(loser.reset(now: at + RatchetResetPolicy.resetReplacementMilliseconds, cause: .unreadable)).reRooted)
    }

    /// A reclaim is our init taken as a replacement too, so it stamps the sender's `replacedAt` beside the answer floor
    /// (`commitOpen`, knit-next `RatchetSessions.kt:304-306` at `f018bc8ce`, the 2026-11-01 amendment to its ADR 2026-09.qerd):
    /// a forced reset inside the peer's minute is declined, where before it would have re-rooted into the peer's floor.
    @Test func aReclaimStampsTheReplacementFloorForAForcedResetToo() throws {
        let (winner, loser) = try lostAndAnswered()
        let at = Self.t0 + 1000 + Self.skew + 1
        #expect(plaintext(try loser.open(winner.seal("under your init", now: at), now: at, sentAt: at)) != nil)
        #expect(loser.sessions.reclaims == 1)
        guard case .declined(let reason, let plan) = try loser.reset(now: at + 30_000, cause: .onDemand) else {
            Issue.record("a forced re-root inside the peer's minute went out")
            return
        }
        #expect(reason == "the peer adopted our reset under a minute ago" && plan.decidedBy == .replacedInit)
    }

    /// Security review's pin: a frame that is not the race's party's under our lost init never reclaims, however far ahead
    /// its stamp, and the stamp stays set for the frame that may. Both forms: another pinned identity's frame, which reads a
    /// session of its own; and the winner's own frame under the winning root, the session's active root, which only the
    /// `prevRoot` candidate could reclaim from.
    @Test func aFrameFromOutsideTheLostInitNeverReclaimsWhateverItsStamp() throws {
        let (one, two) = try RatchetSessionSide.pair()
        let (winner, loser) = one.nodeId < two.nodeId ? (one, two) : (two, one)
        let opener = try loser.seal("loser opens", now: Self.t0)
        #expect(
            plaintext(try loser.open(winner.seal("winner opens", now: Self.t0 + 1000), now: Self.t0 + 1000, sentAt: Self.t0 + 1000)) != nil)
        let underWinning = try winner.seal("under the winning root", now: Self.t0 + 1001)
        winner.wipe()
        #expect(plaintext(try winner.open(opener, now: Self.t0 + 2000, sentAt: Self.t0)) != nil)
        let lost = try #require(loser.session)
        #expect(lost.prevRootOwnInitAt == Self.t0)
        let farAhead = Self.t0 + 1000 + 100 * Self.skew

        #expect(plaintext(try loser.open(underWinning, now: farAhead, sentAt: farAhead)) != nil, "read under the active root")
        #expect(loser.sessions.reclaims == 0 && loser.session?.root == lost.root)
        #expect(loser.session?.prevRootOwnInitAt == Self.t0, "the stamp stays set")

        let stranger = IdentityKeys.generate()
        let store = MemoryRatchetStore()
        let strangers = RatchetSessions(identity: stranger, store: store, transactor: MemoryTransactor(stores: [store]))
        let loserPrekey = try #require(loser.prekeys[1])
        let pinned = try #require(PeerPrekey(verifying: loserPrekey.info, signedBy: loser.identity.bundle))
        guard
            case .settled(.sealed(let envelope, _)) = strangers.sealDm(
                to: loser.identity.bundle, prekey: pinned, plaintext: Array("hello".utf8), aad: RatchetSessionSide.aad, now: farAhead)
        else {
            Issue.record("the stranger's seal failed")
            return
        }
        let frame = try #require(RatchetSessions.Frame(envelope: envelope, aad: RatchetSessionSide.aad))
        let answer = loser.sessions.open(
            frame,
            from: stranger.bundle,
            now: farAhead,
            sentAt: farAhead,
            prekeys: { [prekeys = loser.prekeys] in prekeys[$0] },
            alongside: { _ in () }
        )
        #expect(plaintext(answer) != nil, "the stranger's own session")
        #expect(loser.sessions.reclaims == 0 && loser.session?.root == lost.root)
        #expect(loser.session?.prevRootOwnInitAt == Self.t0, "the stamp stays set")
    }

    /// Strictly more than the skew past the winning init's stamp, both the peer's clock: at exactly the skew the answer is
    /// read read-only under the lost init, and the next, a millisecond later, reclaims on the chain that read stored.
    @Test func theMarginIsStrict() throws {
        let (winner, loser) = try lostAndAnswered()
        let lost = try #require(loser.session)
        let edge = Self.t0 + 1000 + Self.skew
        #expect(plaintext(try loser.open(winner.seal("at the edge", now: edge), now: edge, sentAt: edge)) != nil)
        #expect(loser.session == lost && loser.sessions.reclaims == 0, "read read-only, nothing moved")
        #expect(plaintext(try loser.open(winner.seal("past it", now: edge + 1), now: edge + 1, sentAt: edge + 1)) != nil)
        #expect(loser.session?.root == winner.session?.root && loser.sessions.reclaims == 1)
    }

    /// A frame with no stamp, a vector replay's, never reclaims, as Kotlin's talk frames never do.
    @Test func aFrameWithNoStampNeverReclaims() throws {
        let (winner, loser) = try lostAndAnswered()
        let lost = try #require(loser.session)
        let late = Self.t0 + 3_600_000
        #expect(plaintext(try loser.open(winner.seal("no stamp", now: late), now: late)) != nil)
        #expect(loser.session == lost)
    }

    /// The start's replay out of our own custody reclaims too: the stamp guards itself, since every other write of the slot
    /// clears it, so a stamp still held means no era moved since the race was lost, and a replayed frame sealed past the
    /// margin is the same evidence as a live one (ADR 2026-10.5sk9's P9a amendment).
    @Test func theStartsReplayReclaimsToo() throws {
        let (winner, loser) = try lostAndAnswered()
        let at = Self.t0 + 1000 + Self.skew + 1
        #expect(plaintext(try loser.open(winner.seal("replayed", now: at), now: at, sentAt: at, allowEraChange: false)) != nil)
        #expect(loser.session?.root == winner.session?.root && loser.sessions.reclaims == 1)
    }

    /// The pure rules (`predates` and `sealedSinceLostRace`, knit-next `RatchetSessions.kt:1071-1097` at `f018bc8ce`): each reads
    /// the raw stamp against the session's own, the skew strict, and an unknown stamp qualifies for neither.
    @Test func theEraJudgementsReadTheRawStampAgainstTheSessionsOwn() {
        var held = RatchetEngine.SessionState(
            peerId: fixtureNodeId(2), confirmed: false, weAreInitiator: true, root: [1], establishedAt: Self.t0)
        #expect(RatchetSessions.predates(held, sentAt: Self.t0 - Self.skew - 1))
        #expect(!RatchetSessions.predates(held, sentAt: Self.t0 - Self.skew), "the skew is strict")
        #expect(!RatchetSessions.predates(held, sentAt: nil) && !RatchetSessions.predates(nil, sentAt: 0))
        held.weAreInitiator = false
        #expect(!RatchetSessions.predates(held, sentAt: 0), "a session the peer started is never judged")

        #expect(!RatchetSessions.sealedSinceLostRace(held, sentAt: Self.t0 + Self.skew + 1), "no init of ours lost to a race")
        held.prevRootOwnInitAt = Self.t0 - 1
        #expect(RatchetSessions.sealedSinceLostRace(held, sentAt: Self.t0 + Self.skew + 1))
        #expect(!RatchetSessions.sealedSinceLostRace(held, sentAt: Self.t0 + Self.skew), "the skew is strict")
        #expect(!RatchetSessions.sealedSinceLostRace(held, sentAt: nil) && !RatchetSessions.sealedSinceLostRace(nil, sentAt: 0))
    }

    /// The re-root's slot rule (knit-next `pendingResetInit`): our own reset, unanswered, over a root it replaced; never a
    /// plain init, a marked one, an answered one, or a reset from no session.
    @Test func thePendingResetRuleReadsTheRowAlone() {
        let reset = RatchetEngine.SessionState(
            peerId: fixtureNodeId(2),
            confirmed: false,
            weAreInitiator: true,
            root: [1],
            prevRoot: [2],
            establishedAt: 7,
            initEphPub: [3],
            lastResetSentAt: 7
        )
        #expect(RatchetSessions.pendingResetInit(reset) == [3])
        for broken in [
            { (state: inout RatchetEngine.SessionState) in state.lastResetSentAt = 0 },
            { $0.lastResetSentAt = 8 },
            { $0.confirmed = true },
            { $0.weAreInitiator = false },
            { $0.prevRoot = nil },
        ] {
            var state = reset
            broken(&state)
            #expect(RatchetSessions.pendingResetInit(state) == nil)
        }
    }
}
