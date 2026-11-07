import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The era an open commits (``KnitCrypto/RatchetEngine/OpenDelta/openedRootTag``, ``OpenedUnder``; knit-next's
/// `RatchetSessions.OpenedUnder`, `RatchetSessions.kt:290-292` at `cad69c77b`), rung by rung: the root tag the frame
/// opened under, and whether that root is the one the session holds once the open commits. A presence key files by it
/// (ADR 2026-11.sv5t), so each rung must name its own candidate, never fall back to the session's root.
@Suite struct OpenedUnderTests {
    static let t0: Int64 = 100_000_000

    /// What `side` committed opening `envelope` at `now`, as the start's replay opens when `replay`, or `nil` when it did not open.
    private func opened(_ side: RatchetSessionSide, _ envelope: EncEnvelope, now: Int64, replay: Bool = false) throws -> OpenedUnder? {
        let frame = try #require(RatchetSessions.Frame(envelope: envelope, aad: RatchetSessionSide.aad))
        var under: OpenedUnder?
        let prekeys = side.prekeys
        let held: (Int) -> SignedPrekey? = { prekeys[$0] }
        let peer = side.peer.identity.bundle
        let answer = side.sessions.open(frame, from: peer, now: now, allowEraChange: !replay, prekeys: held) { opened in
            under = OpenedUnder(opened.delta)
        }
        guard case .settled(.opened) = answer else {
            return nil
        }
        return under
    }

    private func activeTag(_ side: RatchetSessionSide) throws -> Int64 {
        RatchetCrypto.rootTag(try #require(side.session).root)
    }

    @Test func aFreshEpochALiveChainAndASkippedKeyOpenUnderTheActiveRoot() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let fresh = try #require(try opened(bob, alice.seal("one", now: Self.t0), now: Self.t0))
        let tag = try activeTag(bob)
        #expect(fresh == OpenedUnder(rootTag: tag, active: true))
        #expect(try opened(bob, alice.seal("two", now: Self.t0 + 1), now: Self.t0 + 1) == fresh, "the live chain")
        let skipped = try alice.seal("three", now: Self.t0 + 2)
        #expect(try opened(bob, alice.seal("four", now: Self.t0 + 3), now: Self.t0 + 3) == fresh, "past a gap")
        #expect(try opened(bob, skipped, now: Self.t0 + 4) == fresh, "the skipped key")
    }

    /// After a flagged reset is adopted, the new root's frames are active under its tag, and the previous root's tail,
    /// on its live chain or a skipped key, drains under the old tag, never active.
    @Test func aResetsFramesAreActiveAndTheOldRootsTailDrains() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let first = try #require(try opened(bob, alice.seal("one", now: Self.t0), now: Self.t0))
        _ = try opened(alice, bob.seal("back", now: Self.t0 + 1), now: Self.t0 + 1)
        let oldTag = first.rootTag
        let skippedLate = try alice.seal("late one", now: Self.t0 + 2)
        let liveLate = try alice.seal("late two", now: Self.t0 + 3)
        let later = Self.t0 + 2 * RatchetResetPolicy.resetReplacementMilliseconds
        let reset = try sealedReset(alice.reset(now: later))
        let adopted = try #require(try opened(bob, reset.envelope, now: later))
        let newTag = try activeTag(bob)
        #expect(newTag != oldTag)
        #expect(adopted == OpenedUnder(rootTag: newTag, active: true), "the reset's own init")
        #expect(try opened(bob, alice.seal("new", now: later + 1), now: later + 1) == OpenedUnder(rootTag: newTag, active: true))
        #expect(try opened(bob, liveLate, now: later + 2) == OpenedUnder(rootTag: oldTag, active: false), "the old root's tail drains")
        #expect(try opened(bob, skippedLate, now: later + 3) == OpenedUnder(rootTag: oldTag, active: false), "its skipped key too")
    }

    /// Both sides initiate. The loser, the larger node id, adopts the winner's root as it reads the winner's opener, which
    /// opens active under that root; the winner reads the loser's opener under the loser's root, a remnant, never active.
    @Test func aRaceLostAdoptsActiveAndTheWinnerReadsTheRemnantInactive() throws {
        let (one, two) = try RatchetSessionSide.pair()
        let (winner, loser) = one.nodeId < two.nodeId ? (one, two) : (two, one)
        let fromWinner = try winner.seal("winner first", now: Self.t0)
        let fromLoser = try loser.seal("loser first", now: Self.t0)
        let winnersTag = try activeTag(winner)
        let losersOwnTag = try activeTag(loser)
        #expect(winnersTag != losersOwnTag)
        let adopted = try #require(try opened(loser, fromWinner, now: Self.t0 + 1))
        #expect(try activeTag(loser) == winnersTag, "the loser adopted the winner's root")
        #expect(adopted == OpenedUnder(rootTag: winnersTag, active: true))
        let remnant = try #require(try opened(winner, fromLoser, now: Self.t0 + 1))
        #expect(try activeTag(winner) == winnersTag)
        #expect(remnant == OpenedUnder(rootTag: losersOwnTag, active: false))
    }

    /// The start's replay opens with `allowEraChange` off: an init the held session has not resolved neither races nor
    /// replaces it, and is read under the roots held alone, which cannot open the other side's opener. Neither side commits
    /// an open, so no ctl it carried is filed under any era, and neither session's root moves.
    @Test func theStartsReplayReadsAnUnresolvedRaceUnderTheHeldRootsAlone() throws {
        let (one, two) = try RatchetSessionSide.pair()
        let (winner, loser) = one.nodeId < two.nodeId ? (one, two) : (two, one)
        let fromWinner = try winner.seal("winner first", now: Self.t0)
        let fromLoser = try loser.seal("loser first", now: Self.t0)
        let losersOwnTag = try activeTag(loser)
        let winnersTag = try activeTag(winner)
        #expect(try opened(loser, fromWinner, now: Self.t0 + 1, replay: true) == nil)
        #expect(try opened(winner, fromLoser, now: Self.t0 + 1, replay: true) == nil)
        #expect(try activeTag(loser) == losersOwnTag && activeTag(winner) == winnersTag, "no era moved")
    }
}
