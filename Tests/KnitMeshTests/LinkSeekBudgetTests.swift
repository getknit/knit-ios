import KnitMesh
import KnitWire
import Testing

/// The wake budget (ADR 2026-10.mueg): a spell of seeking spends at most eight wakes with no link, then waits for the
/// front, Bluetooth coming back on, or the loss of a link that held. A peer below the floor is heard and never dialed,
/// so each sighting of it is a wake spent for nothing.
@Suite struct LinkSeekBudgetTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high

    private func seeking(budget: Int = 8) -> LinkRig {
        LinkRig(
            local: high, advertisesServiceData: false, background: true, configuration: LinkManager.Configuration(seekWakeBudget: budget))
    }

    /// One sighting of a peer we never dial.
    private func wake(_ rig: LinkRig) {
        _ = rig.handle(.sighted(LinkRig.sighting(low, rssi: -95)))
    }

    @Test func sightingsWithinOneWakeCountOnce() {
        let rig = seeking()
        for _ in 0..<4 {
            wake(rig)
            rig.clock.advance(3000)
        }
        #expect(rig.links.seekWakes == 1)
    }

    @Test func wakesAreCountedFromTheirStart() {
        // iOS chains wakes back to back near busy peers; a gap rule would count these as one.
        let rig = seeking()
        for _ in 0..<5 {
            wake(rig)
            rig.clock.advance(5000)
        }
        #expect(rig.links.seekWakes == 3, "at 0, 10 and 20 s")
    }

    @Test func theLastWakeStillDialsThenSeekingStops() {
        let rig = seeking()
        for _ in 0..<7 {
            wake(rig)
            rig.clock.advance(10_000)
        }
        #expect(rig.links.isSeeking)
        _ = rig.handle(.sighted(LinkRig.sighting(middle)))
        #expect(rig.radio.dials.map(\.address) == [RadioAddress("addr-\(middle)")])
        #expect(rig.radio.seeks == [true, false])
        #expect(rig.log.all.contains("info link seeking off (budget spent after 8 wakes)"))
    }

    @Test func aSpentBudgetHoldsUntilTheFront() {
        let rig = seeking(budget: 2)
        wake(rig)
        rig.clock.advance(10_000)
        wake(rig)
        rig.clock.advance(10_000)
        wake(rig)
        #expect(rig.radio.seeks == [true, false])
        #expect(rig.links.seekWakes == 2, "a sighting after the budget is no wake of seeking's")
        _ = rig.links.setInBackground(false)
        _ = rig.links.setInBackground(true)
        #expect(rig.radio.seeks == [true, false, true])
    }

    @Test func theLossOfALinkThatHeldGivesAFreshSpell() {
        let rig = seeking(budget: 2)
        wake(rig)
        _ = rig.accept(middle, on: ChannelID(40))
        _ = rig.advance(30_000)
        _ = rig.handle(.closed(ChannelID(40)))
        wake(rig)
        #expect(rig.links.isSeeking, "one wake spent of a fresh two")
    }

    @Test func aLinkThatFlappedCarriesTheSpellsWakesOn() {
        let rig = seeking(budget: 2)
        wake(rig)
        _ = rig.accept(middle, on: ChannelID(40))
        _ = rig.advance(5000)
        _ = rig.handle(.closed(ChannelID(40)))
        #expect(rig.links.isSeeking)
        rig.clock.advance(10_000)
        wake(rig)
        #expect(!rig.links.isSeeking, "the second of two")
    }

    @Test func theCountersAccumulateAcrossSpells() {
        let rig = seeking(budget: 2)
        wake(rig)
        rig.clock.advance(10_000)
        wake(rig)
        _ = rig.links.setInBackground(false)
        _ = rig.links.setInBackground(true)
        wake(rig)
        #expect(rig.links.seekWakes == 3)
        #expect(rig.links.seekSpells == 2)
    }
}
