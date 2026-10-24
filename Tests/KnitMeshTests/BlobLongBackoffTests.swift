import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// How a want nobody in reach can serve backs off past the 6 min ceiling (knit-next ADR 2026-10.2drc and its 2026-10-19
/// amendment, ADR 2026-10.8hek), ported from `BlobHolderQueryTest`'s day, deadline, lead and lifted-deadline cases. Bob is
/// linked throughout and lacks the blob; each minute the tick re-arms the want of our own, re-derived from its rows, and
/// steps it. Wall and monotonic times run from different bases (``wallAt(_:)``), so a deadline read against the monotonic
/// clock, or a streak's start read against the wall clock, fails here.
@Suite struct BlobLongBackoffTests {
    private let bob = TestPeer(seed: 2).nodeId
    private let eve = TestPeer(seed: 5).nodeId
    private let photo = BlobHash(of: Array("a photo".utf8))
    private let minute: Int64 = 60_000
    /// A deadline long past, and one a week ahead, on the frame's clock.
    private let past: Int64 = 0
    private var ahead: Int64 { wallAt(0) + 7 * 86_400_000 }

    private func candidate(_ id: NodeId) -> BlobExchange.Candidate {
        BlobExchange.Candidate(id: id, streaming: false, capable: true)
    }

    private func answer(_ exchange: inout BlobExchange, _ peer: NodeId, _ state: BlobHolding, at now: Int64) {
        _ = exchange.recordAnswers(BlobHasContent(items: [BlobHasItem(hash: photo.string, state: state)]), from: peer, now: now)
    }

    /// The tick each minute from `from` through `to`: the re-arm with the deadline `until` gives that minute (`nil`: none),
    /// a step, Bob's NONE to any query, and the step its answer makes. Answers the minutes a cycle opened in, read from the
    /// want's own cycle start.
    private func cycleMinutes(
        _ exchange: inout BlobExchange, from: Int64, through to: Int64, until: (Int64) -> Int64?
    ) -> [Int64] {
        var opened: [Int64] = []
        for tick in from...to {
            let now = tick * minute
            let before = exchange.wants[photo]?.cycleAt
            _ = exchange.recordWant(
                photo, now: now, wall: wallAt(now), author: nil, via: nil, asker: nil, reach: .own(until: until(tick), rederived: true))
            let plan = exchange.decide(photo, among: [candidate(bob)], now: now, wall: wallAt(now))
            if plan.query.contains(bob) {
                answer(&exchange, bob, .notHeld, at: now)
                _ = exchange.decide(photo, among: [candidate(bob)], now: now, wall: wallAt(now))
            }
            if exchange.wants[photo]?.cycleAt != before {
                opened.append(tick)
            }
        }
        return opened
    }

    @Test func aDayOfDeadCyclesWithNoDeadlineStretchesTheGapIntoHours() {
        // `aDayOfDeadCyclesStretchesTheGapIntoHoursAndALeadOrANewcomerStillActsAtOnce`: no deadline (a group's picture), so
        // only a day of the dead streak, on the monotonic clock, backs it off past 6 min.
        var exchange = BlobExchange(queriesHolders: true)
        let opened = cycleMinutes(&exchange, from: 0, through: 2010) { _ in nil }
        let gaps = zip(opened.dropFirst(), opened).map { $0 - $1 }
        #expect(Array(gaps.prefix(3)) == [1, 2, 3], "45 s, 90 s, 3 min")
        let firstPastDay = opened.firstIndex(of: 1440) ?? opened.count
        #expect(gaps[3..<(firstPastDay - 1)].allSatisfy { $0 == 6 }, "then 6 min for a day")
        #expect(opened.filter { $0 >= 1440 } == [1440, 1452, 1476, 1524, 1620, 1812, 2004], "then doubling on, to about 3.2 h")
    }

    @Test func aWantPastItsDeadlineBacksOffIntoHoursFromItsFifthDeadCycle() {
        // `aWantPastItsDeadlineBacksOffIntoHoursFromItsFifthDeadCycleWithNoDayOfStreak`: a restart forgets the streak, so
        // the deadline, re-derived at every re-arm, is what backs it off (knit-next's device log of 2026-10-19).
        var exchange = BlobExchange(queriesHolders: true)
        let opened = cycleMinutes(&exchange, from: 0, through: 600) { _ in past }
        #expect(opened == [0, 1, 3, 6, 12, 24, 48, 96, 192, 384, 576], "45 s, 90 s, 3 min, 6 min, then 12 min up to about 3.2 h")
        #expect(exchange.counts.pullThroughs == 0, "nobody was asked to pull it")
        #expect(exchange.counts.pullsWithheld == opened.count, "each dead cycle said so once")
    }

    @Test func aWantWhoseDeadlineIsAheadKeepsTheSixMinuteCeiling() {
        var exchange = BlobExchange(queriesHolders: true)
        let opened = cycleMinutes(&exchange, from: 0, through: 120) { _ in ahead }
        let gaps = zip(opened.dropFirst(), opened).map { $0 - $1 }
        #expect(Array(gaps.prefix(3)) == [1, 2, 3])
        #expect(gaps.count > 3 && gaps.dropFirst(3).allSatisfy { $0 == 6 }, "then 6 min, no further: \(gaps)")
        #expect(exchange.counts.pullsWithheld == 0, "and it pulls every cycle")
    }

    @Test func aLeadEndsADeadlinesLongBackoffAndTheRampStartsOver() {
        var exchange = BlobExchange(queriesHolders: true)
        #expect(cycleMinutes(&exchange, from: 0, through: 200) { _ in past }.last == 192, "deep in the long backoff")
        // Eve links and is fetching it: a lead, so the streak is over.
        let now = 201 * minute
        exchange.linked([eve])
        let plan = exchange.decide(photo, among: [candidate(bob), candidate(eve)], now: now, wall: wallAt(now))
        #expect(plan.query == [eve], "a newcomer is queried at once")
        answer(&exchange, eve, .fetching, at: now)
        #expect(exchange.wants[photo]?.deadCycles == 0)
        // Eve goes as she came: the ramp starts over from 45 s, and backs off past 6 min only at its fifth dead cycle.
        exchange.unlinked([eve])
        #expect(cycleMinutes(&exchange, from: 202, through: 240) { _ in past } == [202, 203, 205, 208, 214, 226])
    }

    @Test func aDeadlineLiftedMidStreakDropsBackToSixMinutesAndRestoredRampsAgain() {
        // Past the deadline to minute 24, none from 25 (a group row names it too), the deadline back from 45. Lifted, the
        // cycle opened at 24 pulls Bob at 25 and stands 6 min from that pull, no longer 12.
        var exchange = BlobExchange(queriesHolders: true)
        let opened = cycleMinutes(&exchange, from: 0, through: 90) { tick in (25...44).contains(tick) ? nil : past }
        #expect(opened == [0, 1, 3, 6, 12, 24, 31, 37, 43, 49, 61, 85], "back to 6 min while lifted, then 12 and 24 again, not 48")
    }

    @Test func theCycleLineSaysHowLongTheNextDeadCycleWaits() {
        var exchange = BlobExchange(queriesHolders: true)
        _ = cycleMinutes(&exchange, from: 0, through: 11) { _ in past }
        let now = 12 * minute
        let plan = exchange.decide(photo, among: [candidate(bob)], now: now, wall: wallAt(now))
        // A gap past 360000 ms means a want dead for a day or past its deadline (knit-next ADR 2026-10.2drc's oracle).
        #expect(plan.notes.first == "blob cycle \(photo.string.prefix(8))… after 4 dead, next if dead in 720000 ms")
    }
}
