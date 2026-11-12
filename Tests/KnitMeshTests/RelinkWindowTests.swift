import KnitWire
import Testing

@testable import KnitMesh

/// The relink window's own rules (``RelinkWindow``): it opens only for a proven link the radio closed, keyed by id, lasts
/// 30 s, and only a proven registration closes it, never an admission.
@Suite struct RelinkWindowTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let closedAt: Int64 = 1000

    private func opened(proven: Bool = true) -> RelinkWindow {
        var window = RelinkWindow(lengthMilliseconds: 30_000)
        window.radioClosed(low, proven: proven, now: closedAt)
        return window
    }

    @Test func itOpensOnlyForAProvenLink() {
        let unproven = opened(proven: false)
        #expect(!unproven.admits(low, now: closedAt + 1))
        let proven = opened()
        #expect(proven.admits(low, now: closedAt + 1))
    }

    @Test func itIsKeyedByTheIdAlone() {
        let window = opened()
        #expect(!window.admits(middle, now: closedAt + 1))
        #expect(window.admits(low, now: closedAt + 1))
    }

    @Test func itLastsThirtySecondsOnTheMonotonicClock() {
        var window = opened()
        #expect(window.admits(low, now: closedAt + 29_999))
        #expect(!window.admits(low, now: closedAt + 30_000))
        window.prune(now: closedAt + 30_000)
        #expect(!window.admits(low, now: closedAt + 1), "pruned once expired, so not open even at an earlier reading")
    }

    @Test func anAdmissionLeavesItOpenAndAProvenRegistrationClosesIt() {
        var window = opened()
        #expect(window.admits(low, now: closedAt + 1))
        #expect(window.admits(low, now: closedAt + 2), "admitting a dialer is no relink: its proof may fail")
        window.relinked(low)
        #expect(!window.admits(low, now: closedAt + 3))
    }

    @Test func aLaterCloseStartsItAgainAndAnOpeningPrunesTheExpired() {
        var window = opened()
        window.radioClosed(low, proven: true, now: closedAt + 20_000)
        #expect(window.admits(low, now: closedAt + 45_000))
        window.radioClosed(middle, proven: true, now: closedAt + 100_000)
        #expect(!window.admits(low, now: closedAt + 20_001), "pruned by the opening")
        #expect(window.admits(middle, now: closedAt + 100_001))
    }

    @Test func aLengthOfZeroNeverAdmits() {
        var window = RelinkWindow(lengthMilliseconds: 0)
        window.radioClosed(low, proven: true, now: closedAt)
        #expect(!window.admits(low, now: closedAt))
    }

    @Test func clearingForgetsEveryWindow() {
        var window = opened()
        window.clear()
        #expect(!window.admits(low, now: closedAt + 1))
    }
}
