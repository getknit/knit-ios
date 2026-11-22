import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A release is timed when its round is credited (the `custody-carry-policy` contract, §6, revision 21): the judging delay,
/// the pending lapse and the answer's forgetting run from the look that credits the round, or from the credit's drop on a
/// live link, never from the cut. Paired with Android's `ForwardSync.settleHandoffs` (`ForwardSync.kt:711-747`) and
/// `ForwardSyncTest.aRoundAgedOnAFullLinkIsWrittenAtItsDropAndJudgedFromThere`.
extension MeshEngineCustodyAnswerTests {
    /// The bytes that hold a link full: more than a round unwritten.
    private static let full = 10 * CustodySync.roundBytes

    /// One DM for Dave in custody, cut to Bob behind a link that then stays full, so its round waits for its credit.
    private func cutBehindAFullLink() throws -> (EngineFixture, String) {
        let (fixture, ids) = try fixture(dms: 1)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(served(fixture, to: bob).map(\.envelope.id) == ids)
        fixture.transport.unwritten[bob.nodeId] = Self.full
        #expect(fixture.engine.custody.ledger.creditsWaiting == [bob.nodeId])
        return (fixture, ids[0])
    }

    /// Whether Bob's memo marks `id` not kept.
    private func marked(_ id: String, in fixture: EngineFixture) -> Bool {
        fixture.engine.custody.ledger.memos[bob.nodeId]?.notKept[ExactKey(id)] != nil
    }

    @Test func aRoundCreditedPastTheJudgingDelayIsNotJudgedByADigestBefore() throws {
        let (fixture, id) = try cutBehindAFullLink()
        // 25 s after the cut, the round still below the link: a digest lacking it can't speak to it.
        fixture.advance(25_000)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(!marked(id, in: fixture), "no not-kept mark")
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId)?.skips(ExactKey(id)) == true, "the answer remembers it")
        #expect(!fixture.engine.custody.ledger.isPending(ExactKey(id), for: bob.nodeId, now: 25_000), "pending only at its credit")
    }

    @Test func aCreditedRoundIsJudgedTwentySecondsAfterItsCredit() throws {
        let (fixture, id) = try cutBehindAFullLink()
        fixture.advance(25_000)
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.advance(Self.look)
        let credited = fixture.clock.monotonicMilliseconds()
        #expect(fixture.engine.custody.ledger.memos[bob.nodeId]?.pending[ExactKey(id)] == credited, "pending from the credit")
        fixture.transport.unwritten[bob.nodeId] = Self.full
        fixture.advance(CarryLedger.judgeAfterMilliseconds - 1)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(!marked(id, in: fixture), "inside 20 s of the credit")
        fixture.advance(1)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(marked(id, in: fixture), "20 s after the credit: judged, not kept")
    }

    /// Pins behaviour that predates revision 21, Android's `Verdict.LinkGone`: link-down already dropped the peer's memo, so
    /// this passes on the cut-timed code too.
    @Test func aCreditDroppedWithItsLinkLeavesNothingPending() throws {
        let (fixture, id) = try cutBehindAFullLink()
        fixture.unlink(bob)
        #expect(fixture.engine.custody.ledger.creditsWaiting.isEmpty)
        #expect(!fixture.engine.custody.ledger.hasMemo(for: bob.nodeId), "nothing pending")
        fixture.link(bob)
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.transport.clear()
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(served(fixture, to: bob).map(\.envelope.id) == [id], "owed again at once")
    }

    @Test func aCreditAgedOnALiveLinkIsTimedFromItsDropAndOwedAgainThen() throws {
        let (fixture, id) = try cutBehindAFullLink()
        let cut = fixture.clock.monotonicMilliseconds()
        // A digest keeps the answer open while the link stays full.
        fixture.advance(100_000)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(!marked(id, in: fixture))
        fixture.advance(cut + CustodyAnswers.maxAgeMilliseconds - fixture.clock.monotonicMilliseconds())
        let dropped = fixture.clock.monotonicMilliseconds()
        #expect(fixture.engine.custody.ledger.creditsWaiting.isEmpty, "dropped uncredited")
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId)?.released[ExactKey(id)] == dropped, "timed at the drop")
        #expect(fixture.engine.custody.ledger.spread(of: id) == 0, "no holder")
        #expect(!fixture.engine.custody.ledger.isPending(ExactKey(id), for: bob.nodeId, now: dropped), "and not pending")
        // Drained, the answer does not queue it again behind itself.
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.transport.clear()
        fixture.advance(Self.look)
        #expect(served(fixture, to: bob).isEmpty)
        // The first digest 20 s past the drop that still lacks it owes it again, and marks nothing.
        fixture.advance(dropped + CarryLedger.judgeAfterMilliseconds - fixture.clock.monotonicMilliseconds())
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(served(fixture, to: bob).map(\.envelope.id) == [id], "owed again")
        #expect(!marked(id, in: fixture))
    }

    @Test func aFrameIsNotCutAgainWhileItsCreditWaits() throws {
        // An unproven link keeps no memo, so only the answer keeps the frame from going again.
        let (fixture, ids) = try fixture(dms: 1)
        fixture.transport.unproven = [bob.nodeId]
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.transport.unwritten[bob.nodeId] = Self.full
        fixture.advance(21_000)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.advance(Self.look)
        #expect(served(fixture, to: bob).map(\.envelope.id) == ids, "cut once: the digest 21 s after the cut forgot nothing")
    }

    @Test func aFrameWhoseCreditDiedWithItsRowIsServedAgainInTheSameAnswer() throws {
        // Evicted and written again with no cut between: the ledger forgets the id in its credit, and the answer must too.
        let (fixture, _) = try fixture(dms: 60)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        let id = try #require(served(fixture, to: bob).first?.envelope.id)
        fixture.transport.unwritten[bob.nodeId] = Self.full
        fixture.advance(Self.look)
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId)?.uncredited.contains(ExactKey(id)) == true)
        fixture.engine.custody.ledger.forget(id)
        fixture.transport.unwritten[bob.nodeId] = 0
        for _ in 0..<10 {
            fixture.advance(Self.look)
        }
        #expect(served(fixture, to: bob).count { $0.envelope.id == id } == 2, "served again in the same answer")
    }
}
