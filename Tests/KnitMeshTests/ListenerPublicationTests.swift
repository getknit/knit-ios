import KnitMesh
import Testing

/// The CoreBluetooth radio's L2CAP listener across a stop and a start, with the unpublish's answer landing before the
/// start, after it, late or never. A publish sent behind an unanswered unpublish gets another PSM, so a start waits for
/// the answer, for at most ``ListenerPublication/answerWaitMilliseconds``, and nothing here tells channels apart by PSM.
@Suite struct ListenerPublicationTests {
    /// A ``ListenerPublication`` behind a reference, so `#expect` can check what a mutating call answers.
    private final class Listener {
        var state = ListenerPublication()

        func shouldPublish() -> Bool { state.shouldPublish() }
        func stop() -> ListenerPublication.Unpublish? { state.stop() }
        func published(_ psm: UInt16, running: Bool = true) -> ListenerPublication.Published {
            state.published(psm, running: running)
        }
        func unpublished(_ psm: UInt16) -> ListenerPublication.Unpublished { state.unpublished(psm) }
        func waitEnded(_ wait: UInt64) -> Int { state.waitEnded(wait) }

        /// Published on 192 and reported.
        static func live() -> Listener {
            let listener = Listener()
            _ = listener.shouldPublish()
            _ = listener.published(192)
            return listener
        }
    }

    @Test func theWaitIsFiveSeconds() {
        #expect(ListenerPublication.answerWaitMilliseconds == 5000)
    }

    @Test func aStartPublishesOnceAndTheAnswerIsReported() {
        let listener = Listener()
        #expect(listener.shouldPublish())
        #expect(!listener.shouldPublish(), "one publish in flight at a time")
        #expect(listener.published(192) == .listening(192))
        #expect(listener.state.psm == 192)
        #expect(!listener.shouldPublish(), "a live listener is not published again")
    }

    @Test func anUnpublishAnsweredBeforeTheStartLetsTheStartPublish() throws {
        let listener = Listener.live()
        let unpublish = try #require(listener.stop())
        #expect(unpublish.psm == 192)
        #expect(listener.state.psm == nil)
        #expect(listener.unpublished(192) == .asked)
        #expect(listener.shouldPublish())
        #expect(listener.published(192) == .listening(192))
        #expect(listener.waitEnded(unpublish.wait) == 0, "an answered wait gives up nothing")
    }

    /// The 2026-10-04 `iphone-react` run: the start came one round trip behind the stop. It found the PSM still set
    /// and published nothing, and the late answer then cleared it, so nothing listened on 192 for 7 minutes. Published
    /// behind the unanswered unpublish instead, it was handed 193 (2026-10-14).
    @Test func aStartBeforeTheAnswerWaitsAndPublishesOnIt() {
        let listener = Listener.live()
        _ = listener.stop()
        #expect(!listener.shouldPublish(), "a publish behind the unanswered unpublish would get another PSM")
        #expect(listener.unpublished(192) == .asked)
        #expect(listener.shouldPublish(), "the answer lets a running radio publish")
        #expect(listener.published(192) == .listening(192), "and the PSM is reported again, so it is advertised")
        #expect(listener.state.psm == 192)
    }

    /// A manager that refuses the unpublish never answers it (CoreBluetooth's API MISUSE).
    @Test func aLostAnswerHoldsThePublishBackOnlyUntilTheDeadline() throws {
        let listener = Listener.live()
        let unpublish = try #require(listener.stop())
        #expect(!listener.shouldPublish())
        #expect(listener.waitEnded(unpublish.wait) == 1)
        #expect(listener.state.unpublishing == 0)
        #expect(listener.state.late == 1)
        #expect(listener.shouldPublish(), "the deadline lets a running radio publish")
        #expect(listener.waitEnded(unpublish.wait) == 0, "and a second firing does nothing")
    }

    @Test func aLateAnswerAfterTheDeadlineKeepsTheNewChannel() throws {
        let listener = Listener.live()
        let unpublish = try #require(listener.stop())
        _ = listener.waitEnded(unpublish.wait)
        _ = listener.shouldPublish()
        #expect(listener.published(192) == .listening(192))
        #expect(listener.unpublished(192) == .late, "it carries the new channel's PSM, and is not a drop")
        #expect(listener.state.psm == 192)
        #expect(listener.state.late == 0)
        #expect(listener.unpublished(192) == .dropped, "the next unasked answer for the live PSM is a drop again")
    }

    @Test func aLateAnswerGoesBeforeOneStillWaitedOn() throws {
        let listener = Listener.live()
        let first = try #require(listener.stop())
        _ = listener.waitEnded(first.wait)
        _ = listener.shouldPublish()
        _ = listener.published(193)
        _ = listener.stop()
        #expect(listener.unpublished(192) == .late, "the stack answers in order, so the oldest owed comes first")
        #expect(!listener.shouldPublish(), "the second stop's answer is still waited on")
        #expect(listener.unpublished(193) == .asked)
        #expect(listener.shouldPublish())
    }

    @Test func aDeadlineANewerStopReplacedDoesNothing() throws {
        let listener = Listener.live()
        let first = try #require(listener.stop())
        _ = listener.unpublished(192)
        _ = listener.shouldPublish()
        _ = listener.published(192)
        let second = try #require(listener.stop())
        #expect(second.wait != first.wait)
        #expect(listener.waitEnded(first.wait) == 0, "the first stop's deadline does not cut the second's wait")
        #expect(!listener.shouldPublish())
        #expect(listener.waitEnded(second.wait) == 1)
        #expect(listener.shouldPublish())
    }

    @Test func aPublishThatLandsAfterTheStopIsUnpublishedAndTheNextStartWaitsForIt() {
        let listener = Listener()
        _ = listener.shouldPublish()
        #expect(listener.stop() == nil, "nothing is live to unpublish yet")
        guard case .unpublish(let unpublish) = listener.published(192, running: false) else {
            Issue.record("a publish that lands while stopped is unpublished")
            return
        }
        #expect(unpublish.psm == 192)
        #expect(listener.state.psm == nil)
        #expect(!listener.shouldPublish(), "the start waits for that unpublish too")
        #expect(listener.unpublished(192) == .asked)
        #expect(listener.shouldPublish())
        #expect(listener.published(192) == .listening(192))
    }

    @Test func aPublishThatLandsAfterAStopAndAStartIsKept() {
        let listener = Listener()
        _ = listener.shouldPublish()
        _ = listener.stop()
        #expect(!listener.shouldPublish(), "the publish still in flight serves the start")
        #expect(listener.published(192) == .listening(192))
    }

    @Test func aFailedPublishIsAskedAgain() {
        let listener = Listener()
        _ = listener.shouldPublish()
        listener.state.publishFailed()
        #expect(listener.shouldPublish())
    }

    @Test func aStopTheManagerCannotTakeForgetsThePSMAndCountsOnNoAnswer() {
        let listener = Listener.live()
        listener.state.forget()
        #expect(listener.state.psm == nil)
        #expect(listener.state.unpublishing == 0)
        #expect(listener.shouldPublish())
    }

    @Test func anUnaskedUnpublishOfTheLiveListenerIsADrop() {
        let listener = Listener.live()
        #expect(listener.unpublished(192) == .dropped)
        #expect(listener.state.psm == nil)
        #expect(listener.shouldPublish())
    }

    @Test func anUnaskedUnpublishOfAnotherPSMIsIgnored() {
        let listener = Listener.live()
        #expect(listener.unpublished(193) == .stray)
        #expect(listener.state.psm == 192)
        let idle = Listener()
        #expect(idle.unpublished(192) == .stray)
    }

    @Test func goingOffForgetsEveryAnswerAndDeadlineOwed() throws {
        let listener = Listener.live()
        let waited = try #require(listener.stop())
        _ = listener.shouldPublish()
        _ = listener.published(193, running: false)
        listener.state.poweredOff()
        #expect(listener.state.psm == nil)
        #expect(listener.state.unpublishing == 0)
        #expect(listener.state.late == 0)
        #expect(listener.shouldPublish(), "nothing owed before the power cycle holds the publish back")
        #expect(listener.unpublished(192) == .stray, "and an answer that comes late anyway is ignored")
        _ = listener.published(192)
        let fresh = try #require(listener.stop())
        #expect(fresh.wait > waited.wait + 1, "generations keep growing through the power cycle")
        #expect(listener.waitEnded(waited.wait) == 0)
        #expect(listener.waitEnded(waited.wait + 1) == 0, "no deadline armed before the power cycle cuts a new wait")
        #expect(!listener.shouldPublish())
    }
}
