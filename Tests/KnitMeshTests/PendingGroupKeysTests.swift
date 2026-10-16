import KnitWire
import Testing

@testable import KnitMesh

/// The park for seeds that outran their roster (ADR 2026-10.5sk9, phase P6a2): knit-next's seven `PendingGroupKeysTest`
/// cases by name (`PendingGroupKeysTest.kt`, at `cbf2a487`), with an injected clock, and this port's own: groups and ids by
/// their bytes, and the route a seed parked with.
@Suite struct PendingGroupKeysTests {
    private func frame(_ id: String, from sender: String) -> RelayEnvelope {
        RelayEnvelope(type: .chat, id: id, senderId: sender, payload: [])
    }

    private let route = RatchetInbound.Route(hop: nil, signed: true, origin: .firstVerdict)

    private func park(
        holdMilliseconds: Int64 = PendingGroupKeys.defaultHoldMilliseconds,
        capacity: Int = PendingGroupKeys.defaultCapacity,
        perGroup: Int = PendingGroupKeys.defaultPerGroup
    ) -> PendingGroupKeys {
        PendingGroupKeys(holdMilliseconds: holdMilliseconds, capacity: capacity, perGroup: perGroup)
    }

    private func ids(_ parked: [PendingGroupKeys.Parked]) -> [String] {
        parked.map(\.envelope.id)
    }

    @Test func heldFrameIsReleasedForItsGroup() {
        var park = PendingGroupKeys()
        let hop = TestPeer(seed: 2).nodeId
        let came = RatchetInbound.Route(hop: hop, signed: true, origin: .firstVerdict)
        #expect(park.hold(frame("s1", from: "alice"), for: "g-1", route: came, now: 0) == .parked)
        let released = park.release("g-1") { _ in true }
        #expect(ids(released) == ["s1"])
        #expect(released.first?.route == came, "the route it came by rides along, as Kotlin keeps the plane")
        #expect(park.release("g-1") { _ in true }.isEmpty, "once released it is gone")
    }

    @Test func releaseReturnsOnlyTheMatchingGroupOldestFirst() {
        var park = PendingGroupKeys()
        _ = park.hold(frame("a1", from: "alice"), for: "g-1", route: route, now: 0)
        _ = park.hold(frame("b1", from: "bob"), for: "g-2", route: route, now: 1)
        _ = park.hold(frame("c1", from: "carol"), for: "g-1", route: route, now: 2)
        #expect(ids(park.release("g-1") { _ in true }) == ["a1", "c1"])
        #expect(ids(park.release("g-2") { _ in true }) == ["b1"])
    }

    @Test func aReServedHeldFrameIsStillReportedHeld() {
        var park = PendingGroupKeys()
        #expect(park.hold(frame("s1", from: "alice"), for: "g-1", route: route, now: 0) == .parked)
        #expect(
            park.hold(frame("s1", from: "alice"), for: "g-1", route: route, now: 0) == .alreadyParked,
            "the caller skips the commit either way")
        #expect(park.release("g-1") { _ in true }.count == 1, "stored once")
    }

    @Test func releaseLeavesFramesThePredicateRefusesParked() {
        var park = park(holdMilliseconds: 100)
        _ = park.hold(frame("a1", from: "alice"), for: "g-1", route: route, now: 0)
        _ = park.hold(frame("b1", from: "bob"), for: "g-1", route: route, now: 10)
        #expect(ids(park.release("g-1") { $0.envelope.senderId != "bob" }) == ["a1"])
        // Bob's parked at 10, not stamped again at the release: at 120 he is past the 100 ms hold.
        #expect(park.sweep(now: 120) == 1)
        #expect(park.release("g-1") { _ in true }.isEmpty)
    }

    @Test func perGroupCapRefusesBeyondTheLimit() {
        var park = park(perGroup: 2)
        #expect(park.hold(frame("s0", from: "alice"), for: "g-1", route: route, now: 0) == .parked)
        #expect(park.hold(frame("s1", from: "bob"), for: "g-1", route: route, now: 1) == .parked)
        #expect(park.hold(frame("s2", from: "carol"), for: "g-1", route: route, now: 2) == .full, "the ordinary path instead")
        #expect(park.hold(frame("s3", from: "dave"), for: "g-2", route: route, now: 3) == .parked, "another group is not crowded out")
        #expect(ids(park.release("g-1") { _ in true }) == ["s0", "s1"])
    }

    @Test func globalCapEvictsOldestFirst() {
        var park = park(capacity: 2)
        _ = park.hold(frame("s0", from: "alice"), for: "g-0", route: route, now: 0)
        _ = park.hold(frame("s1", from: "alice"), for: "g-1", route: route, now: 1)
        _ = park.hold(frame("s2", from: "alice"), for: "g-2", route: route, now: 2)
        #expect(park.release("g-0") { _ in true }.isEmpty, "the oldest went under the global cap")
        #expect(ids(park.release("g-1") { _ in true }) == ["s1"])
        #expect(ids(park.release("g-2") { _ in true }) == ["s2"])
    }

    @Test func sweepExpiredDropsFramesPastTtlButKeepsFresh() {
        var park = park(holdMilliseconds: 100)
        _ = park.hold(frame("old", from: "alice"), for: "g-1", route: route, now: 0)
        _ = park.hold(frame("new", from: "bob"), for: "g-1", route: route, now: 80)
        #expect(park.sweep(now: 150) == 1)
        #expect(ids(park.release("g-1") { _ in true }) == ["new"])
    }

    /// Kotlin's own: the hold is an hour, 64 seeds in all and 16 a group (`PendingGroupKeys.kt:115-121`).
    @Test func theBoundsAreKnitNexts() {
        #expect(PendingGroupKeys.defaultHoldMilliseconds == 3_600_000)
        #expect(PendingGroupKeys.defaultCapacity == 64 && PendingGroupKeys.defaultPerGroup == 16)
    }

    /// This port's own: a group and a frame id go by their bytes (ADR 2026-09.jc2x), so two spellings Swift calls equal are
    /// two groups and two frames.
    @Test func groupsAndIdsCompareByTheirBytes() {
        var park = PendingGroupKeys()
        let composed = "g-\u{00E9}"
        let decomposed = "g-e\u{0301}"
        #expect(park.hold(frame("\u{00E9}", from: "alice"), for: composed, route: route, now: 0) == .parked)
        #expect(park.hold(frame("e\u{0301}", from: "alice"), for: decomposed, route: route, now: 0) == .parked, "another id")
        #expect(ids(park.release(decomposed) { _ in true }) == ["e\u{0301}"])
        #expect(ids(park.release(composed) { _ in true }) == ["\u{00E9}"])
    }
}
