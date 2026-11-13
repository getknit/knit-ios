import KnitMesh
import Testing

/// The CoreBluetooth radio's L2CAP listener across a stop and a start, with the unpublish's answer landing before the
/// start, after it, late or never. A publish sent behind an unanswered unpublish gets another PSM, so a start waits for
/// the answer, for at most ``ListenerPublication/answerWaitMilliseconds``, and nothing here tells channels apart by PSM.
/// A wait that runs out recycles the peripheral manager, at most ``ListenerPublication/maximumRecycles`` times, and then
/// publishes on the same one (knit/knit-ios#53).
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
        func waitEnded(_ wait: UInt64) -> ListenerPublication.Expiry { state.waitEnded(wait) }
        func managerPoweredOn() -> Bool { state.managerPoweredOn() }

        /// Published on 192 and reported.
        static func live() -> Listener {
            let listener = Listener()
            _ = listener.shouldPublish()
            _ = listener.published(192)
            return listener
        }

        /// Published on 192 with every recycle spent: each a stop whose answer never came, then the new manager's
        /// power-on and its publish.
        static func spent() -> Listener {
            let listener = live()
            for _ in 0..<ListenerPublication.maximumRecycles {
                if let unpublish = listener.stop() {
                    _ = listener.waitEnded(unpublish.wait)
                }
                _ = listener.managerPoweredOn()
                _ = listener.shouldPublish()
                _ = listener.published(192)
            }
            return listener
        }

        /// A live listener whose stop's answer never came, recycled once and waiting for the new manager.
        static func recycling() throws -> (Listener, ListenerPublication.Unpublish) {
            let listener = live()
            let unpublish = try #require(listener.stop())
            #expect(listener.waitEnded(unpublish.wait) == .recycle(expired: 1, ordinal: 1))
            return (listener, unpublish)
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
        #expect(listener.waitEnded(unpublish.wait) == .answered, "an answered wait gives up nothing")
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

    /// A manager that refuses the unpublish never answers it (CoreBluetooth's API MISUSE). Once every recycle is spent,
    /// the deadline publishes on the same manager, as the radio did before knit/knit-ios#53.
    @Test func aLostAnswerHoldsThePublishBackOnlyUntilTheDeadline() throws {
        let listener = Listener.spent()
        let unpublish = try #require(listener.stop())
        #expect(!listener.shouldPublish())
        #expect(listener.waitEnded(unpublish.wait) == .publish(expired: 1))
        #expect(listener.state.unpublishing == 0)
        #expect(listener.state.late == 1)
        #expect(listener.state.recycles == ListenerPublication.maximumRecycles)
        #expect(listener.shouldPublish(), "the deadline lets a running radio publish")
        #expect(listener.waitEnded(unpublish.wait) == .answered, "and a second firing does nothing")
    }

    @Test func aLateAnswerAfterTheDeadlineKeepsTheNewChannel() throws {
        let listener = Listener.spent()
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
        let listener = Listener.spent()
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
        #expect(listener.waitEnded(first.wait) == .answered, "the first stop's deadline does not cut the second's wait")
        #expect(!listener.shouldPublish())
        #expect(listener.waitEnded(second.wait) == .recycle(expired: 1, ordinal: 1))
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
        #expect(listener.waitEnded(waited.wait) == .answered)
        #expect(listener.waitEnded(waited.wait + 1) == .answered, "no deadline armed before the power cycle cuts a new wait")
        #expect(!listener.shouldPublish())
    }
}

// MARK: Recycling the peripheral manager (knit/knit-ios#53)

extension ListenerPublicationTests {
    /// Run `3a7576`: the publish behind an unanswered unpublish was handed PSM 193, which bluetoothd had no endpoint for.
    /// The expired wait recycles the manager instead, and forgets what the old one held or owed, as a power-off does.
    @Test func anExpiredWaitRecyclesThePeripheralManagerAndForgetsTheOldOne() throws {
        let listener = Listener.live()
        let unpublish = try #require(listener.stop())
        #expect(listener.waitEnded(unpublish.wait) == .recycle(expired: 1, ordinal: 1))
        #expect(listener.state.psm == nil)
        #expect(!listener.state.publishing)
        #expect(listener.state.unpublishing == 0)
        #expect(listener.state.late == 0, "the old manager's answer never reaches this radio, so none is owed")
        #expect(listener.state.generation > unpublish.wait, "and its deadline does nothing again")
        #expect(listener.state.recycles == 1)
        #expect(listener.state.recycling)
        #expect(listener.waitEnded(unpublish.wait) == .answered)
    }

    /// Counted late, the old manager's answer that never comes would file the new manager's first real answer as
    /// `.late`, so every later stop would wait out its deadline and recycle again.
    @Test func afterARecycleTheNextStopsAnswerIsAskedNotLate() throws {
        let (listener, _) = try Listener.recycling()
        #expect(listener.managerPoweredOn())
        #expect(listener.shouldPublish())
        #expect(listener.published(192) == .listening(192))
        let next = try #require(listener.stop())
        #expect(listener.unpublished(192) == .asked)
        #expect(listener.waitEnded(next.wait) == .answered)
        #expect(listener.state.recycles == 1, "an answered stop spends no recycle")
        #expect(listener.shouldPublish())
    }

    /// A new manager starts `.unknown` and refuses a publish unanswered until it is powered on (API MISUSE, e9e6b12), and
    /// the radio's own state stays on through the recycle, so the latch is what holds the publish.
    @Test func aRecycleHoldsThePublishUntilTheNewManagerIsPoweredOn() throws {
        let (listener, _) = try Listener.recycling()
        #expect(!listener.shouldPublish(), "the new manager is not powered on yet")
        #expect(!listener.state.publishing)
        #expect(listener.managerPoweredOn(), "its power-on resumes the radio")
        #expect(!listener.state.recycling)
        #expect(listener.shouldPublish())
        #expect(!listener.managerPoweredOn(), "a later power-on is no recycle's")
    }

    @Test func aPowerOnWithNoRecycleResumesNothingExtra() {
        let listener = Listener()
        #expect(!listener.managerPoweredOn())
        #expect(listener.shouldPublish())
    }

    /// The manager's not powered on, so the radio forgets rather than unpublishes, and nothing is owed that could expire.
    @Test func aStopDuringARecycleOwesNothing() throws {
        let (listener, _) = try Listener.recycling()
        #expect(listener.stop() == nil)
        listener.state.forget()
        #expect(listener.state.unpublishing == 0)
        #expect(listener.state.recycling, "the new manager's power-on still ends the recycle")
        #expect(listener.managerPoweredOn())
        #expect(listener.shouldPublish())
    }

    /// Another expiry while the new manager is on its way publishes on it once it is up, and makes no second manager.
    @Test func oneRecycleRunsAtATime() throws {
        let (listener, _) = try Listener.recycling()
        guard case .unpublish(let owed) = listener.published(193, running: false) else {
            Issue.record("a publish that lands while stopped is unpublished")
            return
        }
        #expect(listener.waitEnded(owed.wait) == .publish(expired: 1), "no second recycle while one is under way")
        #expect(listener.state.recycles == 1)
        #expect(listener.state.recycling)
        #expect(!listener.shouldPublish(), "still held for the new manager")
        #expect(listener.managerPoweredOn())
        #expect(listener.shouldPublish())
    }

    @Test func theRecyclesAreCappedAndThenTheRadioPublishesAnyway() throws {
        let listener = Listener.live()
        for ordinal in 1...ListenerPublication.maximumRecycles {
            let unpublish = try #require(listener.stop())
            #expect(listener.waitEnded(unpublish.wait) == .recycle(expired: 1, ordinal: ordinal))
            #expect(listener.managerPoweredOn())
            #expect(listener.shouldPublish())
            _ = listener.published(192)
        }
        let past = try #require(listener.stop())
        #expect(listener.waitEnded(past.wait) == .publish(expired: 1))
        #expect(!listener.state.recycling)
        #expect(listener.state.late == 1)
        #expect(listener.shouldPublish(), "today's publish on the same manager")
    }

    @Test func theCapIsThree() {
        #expect(ListenerPublication.maximumRecycles == 3)
    }

    /// The new manager may report `.poweredOff` before `.poweredOn`. The power-off forgets as ever, but spends no
    /// recycle and gives none back, and the publish still waits for the new manager.
    @Test func aPowerOffDuringARecycleKeepsTheLatchAndTheCount() throws {
        let (listener, unpublish) = try Listener.recycling()
        let before = listener.state.generation
        listener.state.poweredOff()
        #expect(listener.state.recycles == 1)
        #expect(listener.state.recycling)
        #expect(listener.state.generation > before)
        #expect(!listener.shouldPublish())
        #expect(listener.waitEnded(unpublish.wait) == .answered)
        #expect(listener.managerPoweredOn())
        #expect(listener.shouldPublish())
        _ = listener.published(192)
        listener.state.poweredOff()
        #expect(listener.state.recycles == 1, "a power cycle gives no recycle back")
    }

    /// The radio ignores the old manager's callbacks by identity, but an answer that reached this type anyway finds
    /// nothing owed and nothing live.
    @Test func anAnswerFromTheRecycledManagerIsAStray() throws {
        let (listener, _) = try Listener.recycling()
        #expect(listener.unpublished(192) == .stray)
        #expect(listener.state.late == 0)
    }
}
