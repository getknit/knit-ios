import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// Whom to link, ported from knit-next's `PromotionPolicyTest`.
@Suite struct PromotionPolicyTests {
    private let configuration = PromotionPolicy.Configuration(
        dwellMilliseconds: 12_000,
        rssiFloor: -80,
        maxLinks: 3,
        rssiHysteresis: 8,
        minimumHoldMilliseconds: 20_000
    )

    private func candidate(_ seed: Int, rssi: Double, dwell: Int64 = 15_000, quiet: Int64 = 0) -> PresenceTracker.Snapshot {
        PresenceTracker.Snapshot(
            advert: AdvertPayload(capabilities: .local, nodeId: fixtureNodeId(seed), digestCue: 0, psm: 100),
            smoothedRssi: rssi,
            dwellMilliseconds: dwell,
            lastSeenAgoMilliseconds: quiet
        )
    }

    private func link(_ seed: Int, rssi: Double, age: Int64 = 60_000) -> PromotionPolicy.LinkSnapshot {
        PromotionPolicy.LinkSnapshot(nodeId: fixtureNodeId(seed), smoothedRssi: rssi, ageMilliseconds: age)
    }

    private func decide(
        _ candidates: [PresenceTracker.Snapshot],
        links: [PromotionPolicy.LinkSnapshot] = [],
        backoff: Set<Int> = []
    ) -> PromotionPolicy.Decision {
        PromotionPolicy.decide(
            candidates: candidates,
            links: links,
            backoff: Set(backoff.map(fixtureNodeId)),
            configuration: configuration
        )
    }

    private func ids(_ seeds: [Int]) -> [NodeId] { seeds.map(fixtureNodeId) }

    @Test func freeSlotsFillStrongestFirst() {
        let decision = decide([candidate(1, rssi: -70), candidate(2, rssi: -50), candidate(3, rssi: -60)])
        #expect(decision.promote == ids([2, 3, 1]))
        #expect(decision.evict.isEmpty)
    }

    @Test func theRssiFloorAndDwellGatePromotion() {
        let decision = decide([candidate(1, rssi: -85), candidate(2, rssi: -50, dwell: 5000), candidate(3, rssi: -55)])
        #expect(decision.promote == ids([3]), "only the close peer that stayed promotes")
    }

    @Test func aPeerQuietForMoreThanEightSecondsIsSkipped() {
        // This port's rule, not Android's (ADR 2026-09.6es2, amended 2026-09-29).
        let decision = decide([candidate(1, rssi: -50, quiet: 8001), candidate(2, rssi: -60, quiet: 8000)])
        #expect(decision.promote == ids([2]))
    }

    @Test func theWaitIsForTheSoonestDwellToEnd() {
        let candidates = [candidate(1, rssi: -50, dwell: 5000, quiet: 1000), candidate(2, rssi: -60, dwell: 9000, quiet: 2000)]
        #expect(PromotionPolicy.untilDwellEnds(candidates: candidates, backoff: [], configuration: configuration) == 3000)
    }

    @Test func noWaitForAPeerThatWillNotBePromotableWhenItsDwellEnds() {
        func wait(_ candidate: PresenceTracker.Snapshot, backoff: Set<Int> = []) -> Int64? {
            PromotionPolicy.untilDwellEnds(candidates: [candidate], backoff: Set(backoff.map(fixtureNodeId)), configuration: configuration)
        }
        #expect(wait(candidate(1, rssi: -50, dwell: 4000)) == 8000, "8 s quiet by then still counts as heard")
        #expect(wait(candidate(1, rssi: -50, dwell: 4000, quiet: 1)) == nil, "too quiet by then")
        #expect(wait(candidate(1, rssi: -85, dwell: 4000)) == nil, "below the floor")
        #expect(wait(candidate(1, rssi: -50, dwell: 4000), backoff: [1]) == nil, "backing off, which wakes the caller itself")
        #expect(wait(candidate(1, rssi: -50, dwell: 12_000)) == nil, "already past its dwell")
        #expect(PromotionPolicy.untilDwellEnds(candidates: [], backoff: []) == nil)
    }

    @Test func backedOffPeersAreSkipped() {
        #expect(decide([candidate(1, rssi: -50), candidate(2, rssi: -55)], backoff: [1]).promote == ids([2]))
    }

    @Test func theBudgetCapsPromotions() {
        let decision = decide([candidate(1, rssi: -50), candidate(2, rssi: -55), candidate(3, rssi: -60), candidate(4, rssi: -65)])
        #expect(decision.promote == ids([1, 2, 3]))
    }

    @Test func tiesKeepTheirOrder() {
        let decision = decide([candidate(4, rssi: -60), candidate(2, rssi: -60), candidate(9, rssi: -60)])
        #expect(decision.promote == ids([4, 2, 9]))
    }

    @Test func atTheBudgetASlightlyStrongerCandidateWaits() {
        let decision = decide([candidate(9, rssi: -71)], links: [link(1, rssi: -60), link(2, rssi: -65), link(3, rssi: -74)])
        #expect(decision.promote.isEmpty && decision.evict.isEmpty, "within the hysteresis, nothing churns")
    }

    @Test func atTheBudgetAClearlyStrongerCandidateReplacesTheWeakestLink() {
        let decision = decide([candidate(9, rssi: -55)], links: [link(1, rssi: -60), link(2, rssi: -65), link(3, rssi: -74)])
        #expect(decision.promote == ids([9]))
        #expect(decision.evict == ids([3]))
    }

    @Test func linksYoungerThanTheHoldAreNotEvicted() {
        let young = [link(1, rssi: -60, age: 5000), link(2, rssi: -65, age: 5000), link(3, rssi: -74, age: 5000)]
        let decision = decide([candidate(9, rssi: -50)], links: young)
        #expect(decision.promote.isEmpty && decision.evict.isEmpty, "the hold protects new links")
    }

    @Test func anOverflowShedsTheWeakestEvictableLinks() {
        let links = [link(1, rssi: -50), link(2, rssi: -55), link(3, rssi: -60), link(4, rssi: -70), link(5, rssi: -75)]
        let decision = decide([], links: links)
        #expect(Set(decision.evict) == Set(ids([5, 4])))
        #expect(decision.promote.isEmpty)
    }
}
