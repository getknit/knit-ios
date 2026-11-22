import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The answer book (contract §2).
@Suite struct CustodyAnswersTests: CustodySyncCase {
    @Test func aDigestOpensAnAnswerAndANewerOneReplacesItsDigest() {
        var answers = CustodyAnswers()
        let opened = answers.receive([ExactKey("a")], from: bob, now: 1000)
        #expect(opened)
        answers.noteArrived("c", from: bob)
        answers.noteArrived("gone", from: bob)
        var round = CustodySync.DigestReply(
            keysAhead: [alice, bob], released: ["b", "gone-too"].map { CustodySync.Release(id: $0, addressed: false) }, bytes: 100)
        round.live = [ExactKey("b"), ExactKey("c")]
        round.senders = [ExactKey(alice.string)]
        answers.released(round, to: bob)
        #expect(answers.answer(for: bob)?.uncredited == [ExactKey("b")], "trimmed to what custody holds, its credit waiting")
        #expect(answers.answer(for: bob)?.skips(ExactKey("b")) == true, "not cut again meanwhile")
        answers.credited([ExactKey("b"), ExactKey("gone-too")], to: bob, now: 1000)
        let trimmed = answers.answer(for: bob)
        #expect(trimmed?.released == [ExactKey("b"): 1000], "timed at its credit")
        #expect(trimmed?.uncredited.isEmpty == true)
        #expect(trimmed?.arrivedSince == [ExactKey("c")])
        #expect(trimmed?.keysSent == [ExactKey(alice.string)], "and to its senders")
        #expect(answers.timings == [CustodyAnswers.Timing(peer: bob, arrivedAt: 1000)])
        #expect(trimmed?.lastCapped == false, "the round served all there was")
        let reopened = answers.receive([], from: bob, now: 2000)
        #expect(!reopened)
        let answer = answers.answer(for: bob)
        #expect(answer?.arrivedAt == 2000)
        #expect(answer?.listed.isEmpty == true)
        #expect(answer?.released == [ExactKey("b"): 1000], "a release a digest cannot speak to yet stays")
        #expect(answer?.keysSent == [ExactKey(alice.string)])
        #expect(answer?.arrivedSince.isEmpty == true, "what arrived since the older digest, the newer one lists")
        #expect(!answers.isEmpty)
    }

    @Test func aDigestForgetsOnlyTheReleasesItCanSpeakTo() {
        // A release is remembered only until a digest can speak to it (the contract, §2, revision 7).
        var answers = CustodyAnswers()
        answers.receive([], from: bob, now: 0)
        var round = CustodySync.DigestReply(
            keysAhead: [alice], released: [CustodySync.Release(id: "a", addressed: false)], bytes: 100)
        round.live = [ExactKey("a"), ExactKey("b")]
        round.senders = [ExactKey(alice.string)]
        answers.released(round, to: bob)
        answers.credited([ExactKey("a")], to: bob, now: 1000)
        round.released = [CustodySync.Release(id: "b", addressed: true)]
        answers.released(round, to: bob)
        answers.credited([ExactKey("b")], to: bob, now: 15_000)
        answers.receive([], from: bob, now: 20_999)
        #expect(answers.answer(for: bob)?.released == [ExactKey("a"): 1000, ExactKey("b"): 15_000], "inside 20 s: nothing")
        answers.receive([], from: bob, now: 21_000)
        #expect(answers.answer(for: bob)?.released == [ExactKey("b"): 15_000], "a's release is 20 s old: forgotten")
        #expect(answers.answer(for: bob)?.skips(ExactKey("a")) == false)
        #expect(answers.answer(for: bob)?.keysSent == [ExactKey(alice.string)], "a key still goes once per answer")
        answers.receive([], from: bob, now: 35_000)
        #expect(answers.answer(for: bob)?.released.isEmpty == true)
    }

    @Test func anAnswerAgesOutTwoMinutesAfterItsLatestDigest() throws {
        var answers = CustodyAnswers()
        answers.receive([], from: bob, now: 0)
        answers.released(CustodySync.DigestReply(bytes: 2_000_000), to: bob)
        let answer = try #require(answers.answer(for: bob))
        #expect(!CustodyAnswers.isAged(answer, now: 119_999))
        #expect(CustodyAnswers.isAged(answer, now: 120_000))
        answers.end(bob)
        #expect(answers.isEmpty)
        answers.noteArrived("a", from: bob)
        answers.released(CustodySync.DigestReply(), to: bob)
        answers.credited([ExactKey("a")], to: bob, now: 0)
        let waited = answers.waitsOnDrain(bob)
        #expect(!waited)
        #expect(answers.all.isEmpty)
    }

    @Test func aWaitOnTheDrainIsReportedFirstOnce() {
        var answers = CustodyAnswers()
        answers.receive([], from: bob, now: 0)
        let first = answers.waitsOnDrain(bob)
        let second = answers.waitsOnDrain(bob)
        #expect(first)
        #expect(!second)
    }

    @Test func aReleaseIsTimedAtItsCreditAndNoDigestForgetsItBefore() {
        // The contract, §6, revision 21: a round credited 30 s after its cut is not forgotten by a digest 25 s after the
        // cut, and one 20 s after the credit forgets it.
        var answers = CustodyAnswers()
        answers.receive([], from: bob, now: 0)
        var round = CustodySync.DigestReply(released: [CustodySync.Release(id: "a", addressed: false)], bytes: 100)
        round.live = [ExactKey("a")]
        answers.released(round, to: bob)
        answers.receive([], from: bob, now: 25_000)
        #expect(answers.answer(for: bob)?.skips(ExactKey("a")) == true, "uncredited: no digest speaks to it")
        answers.awaitCredit([ExactKey("c")], for: bob)
        #expect(answers.answer(for: bob)?.skips(ExactKey("c")) == true, "an earlier answer's round, still uncredited")
        answers.credited([ExactKey("a")], to: bob, now: 30_000)
        answers.receive([], from: bob, now: 49_999)
        #expect(answers.answer(for: bob)?.released == [ExactKey("a"): 30_000])
        answers.receive([], from: bob, now: 50_000)
        #expect(answers.answer(for: bob)?.skips(ExactKey("a")) == false, "20 s after its credit: forgotten")
        answers.credited([ExactKey("a")], to: bob, now: 60_000)
        #expect(answers.answer(for: bob)?.released.isEmpty == true, "a credit for what the answer no longer waits on times nothing")
        answers.awaitCredit([ExactKey("b")], for: fixtureNodeId(77))
        answers.credited([ExactKey("a")], to: fixtureNodeId(77), now: 60_000)
        #expect(answers.answer(for: fixtureNodeId(77)) == nil)
    }
}
