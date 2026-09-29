import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// Smoothed RSSI, dwell and linger, ported from knit-next's `BlePresenceTrackerTest`. `#expect` cannot call a
/// mutating method, so snapshots are taken first.
@Suite struct PresenceTrackerTests {
    private func sighting(_ seed: Int, rssi: Int, psm: UInt16 = 100) -> PresenceTracker.Sighting {
        PresenceTracker.Sighting(
            advert: AdvertPayload(capabilities: .local, nodeId: fixtureNodeId(seed), digestCue: 0, psm: psm),
            rssi: rssi
        )
    }

    @Test func theFirstSightingSeedsTheRssiWithNoDwell() throws {
        var tracker = PresenceTracker()
        tracker.record(sighting(1, rssi: -60), now: 1000)
        let snapshot = try #require(tracker.snapshots(now: 1000).first)
        #expect(snapshot.smoothedRssi == -60)
        #expect(snapshot.dwellMilliseconds == 0)
        #expect(snapshot.lastSeenAgoMilliseconds == 0)
    }

    @Test func theRssiMovesTowardNewSamples() throws {
        var tracker = PresenceTracker(configuration: .init(rssiSmoothing: 0.5))
        tracker.record(sighting(1, rssi: -60), now: 0)
        tracker.record(sighting(1, rssi: -80), now: 1000)
        let snapshot = try #require(tracker.snapshots(now: 1000).first)
        #expect(snapshot.smoothedRssi == -70)
    }

    @Test func dwellGrowsWhilePresenceIsContinuous() throws {
        var tracker = PresenceTracker()
        tracker.record(sighting(1, rssi: -50), now: 0)
        tracker.record(sighting(1, rssi: -50), now: 3000)
        let snapshot = try #require(tracker.snapshots(now: 5000).first)
        #expect(snapshot.dwellMilliseconds == 5000)
    }

    @Test func aLongGapRestartsDwellAndReseedsTheRssi() throws {
        var tracker = PresenceTracker(configuration: .init(gapResetMilliseconds: 8000))
        tracker.record(sighting(1, rssi: -50), now: 0)
        tracker.record(sighting(1, rssi: -90), now: 9000)
        let snapshot = try #require(tracker.snapshots(now: 9000).first)
        #expect(snapshot.dwellMilliseconds == 0, "dwell restarts")
        #expect(snapshot.smoothedRssi == -90, "the RSSI reseeds rather than averaging across the gap")
    }

    @Test func aPeerIsDroppedAfterTheLinger() {
        var tracker = PresenceTracker(configuration: .init(lingerMilliseconds: 90_000))
        tracker.record(sighting(1, rssi: -50), now: 0)
        let atTheEdge = tracker.snapshots(now: 90_000)
        let past = tracker.snapshots(now: 90_001)
        #expect(atTheEdge.count == 1, "still present exactly at the window")
        #expect(past.isEmpty, "dropped once past the linger")
        #expect(tracker.advert(of: fixtureNodeId(1)) == nil)
    }

    @Test func presenceIsReadWithoutDroppingAnything() {
        var tracker = PresenceTracker(configuration: .init(lingerMilliseconds: 90_000))
        tracker.record(sighting(1, rssi: -50), now: 0)
        tracker.record(sighting(2, rssi: -60), now: 50_000)
        #expect(tracker.present(now: 95_000).map(\.nodeId) == [fixtureNodeId(2)])
        #expect(tracker.advert(of: fixtureNodeId(1)) != nil, "still held, as only snapshots drop it")
        let snapshot = tracker.present(now: 95_000).first
        #expect(snapshot?.dwellMilliseconds == 45_000)
        #expect(snapshot?.lastSeenAgoMilliseconds == 45_000)
    }

    @Test func theLatestAdvertIsKeptForItsPsm() {
        var tracker = PresenceTracker()
        tracker.record(sighting(1, rssi: -55, psm: 137), now: 0)
        tracker.record(sighting(2, rssi: -70, psm: 141), now: 0)
        tracker.record(sighting(1, rssi: -56, psm: 139), now: 10)
        let peers = Set(tracker.snapshots(now: 10).map(\.nodeId))
        #expect(peers == [fixtureNodeId(1), fixtureNodeId(2)])
        #expect(tracker.advert(of: fixtureNodeId(1))?.psm == 139)
        #expect(tracker.smoothedRssi(of: fixtureNodeId(2)) == -70)
        tracker.forget(fixtureNodeId(2))
        #expect(tracker.advert(of: fixtureNodeId(2)) == nil)
    }
}
