import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

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

    /// An unresolved tag is kept under its handle (ADR 2026-11.sv5t); its snapshot, which never leaves the link manager,
    /// answers the advertised bytes for an id, and a resolved one its key's.
    @Test func aSnapshotUnderAHandleAnswersItsAdvertisedForm() throws {
        var tracker = PresenceTracker()
        let handle = SightingKey.form(FormHandle(number: 4))
        tracker.record(sighting(1, rssi: -50), as: handle, now: 0)
        tracker.record(sighting(2, rssi: -50), as: .node(fixtureNodeId(3)), now: 0)
        let snapshots = tracker.snapshots(now: 0)
        #expect(try #require(snapshots.first { $0.key == handle }).nodeId == fixtureNodeId(1))
        #expect(try #require(snapshots.first { $0.key != handle }).nodeId == fixtureNodeId(3))
    }

    /// `BlindReaderTest.aFormsHistoryCarriesToTheIdItResolvesTo`'s tracker half: a handle's history moves to the id it
    /// resolved to, except that an entry the id already had, first seen earlier, stands; the handle's goes either way.
    @Test func aMovedHistoryNeverReplacesAnEarlierOneUnderTheId() throws {
        var tracker = PresenceTracker()
        let handle = SightingKey.form(FormHandle(number: 0))
        let id = fixtureNodeId(1)
        tracker.record(sighting(1, rssi: -40), as: handle, now: 0)
        tracker.move(handle, to: .node(id))
        #expect(tracker.snapshots(now: 5000).map(\.dwellMilliseconds) == [5000], "carried, with its dwell")
        tracker.record(sighting(1, rssi: -90), as: handle, now: 5000)
        tracker.move(handle, to: .node(id))
        let snapshot = try #require(tracker.snapshots(now: 5000).first)
        #expect(tracker.snapshots(now: 5000).count == 1, "the handle's entry went")
        #expect(snapshot.key == .node(id) && snapshot.dwellMilliseconds == 5000, "the id's earlier entry stands")
        #expect(snapshot.smoothedRssi == -40)
        #expect(!tracker.isPresent(handle, now: 5000))
    }
}
