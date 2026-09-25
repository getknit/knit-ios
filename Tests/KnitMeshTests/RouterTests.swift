import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// Flooding and its end, ported from knit-next's `MeshRouterTest`.
@Suite struct RouterTests {
    private let bob = fixtureNodeId(2)
    private let carol = fixtureNodeId(3)
    private let dave = fixtureNodeId(4)
    private let zed = fixtureNodeId(26)

    private func frame(
        _ id: String,
        ttl: Int = WireEnvelope.defaultTTL,
        hops: Int = 0,
        recipient: NodeId? = nil,
        relay: Bool = true,
        type: FrameType = .chat,
        group: GroupInfo? = nil
    ) -> (WireEnvelope, RelayEnvelope) {
        let envelope = RelayEnvelope(type: type, id: id, senderId: "a", recipientId: recipient?.string, group: group, payload: [])
        return (WireEnvelope(ttl: ttl, hops: hops, relay: relay, sig: [], signed: envelope.encoded), envelope)
    }

    private func inbound(_ frame: (WireEnvelope, RelayEnvelope), from neighbor: NodeId) -> InboundFrame {
        InboundFrame(wire: frame.0, envelope: frame.1, from: neighbor)
    }

    /// Admits a frame from `neighbor`, relays it if new, and answers the admission and any immediate sends.
    private func handle(
        _ router: inout Router,
        _ frame: (WireEnvelope, RelayEnvelope),
        from neighbor: NodeId,
        neighbors: [NodeId],
        jitter: Int64 = 0,
        now: Int64 = 0
    ) -> (Router.Admission, [Send]) {
        let admission = router.admit(inbound(frame, from: neighbor), now: now)
        guard admission == .new else {
            return (admission, [])
        }
        return (admission, router.relay(inbound(frame, from: neighbor), neighbors: neighbors, jitter: jitter, now: now))
    }

    @Test func aNewFrameIsAdmittedOnceAndItsRepeatsAreDuplicates() {
        var router = Router()
        let first = router.admit(inbound(frame("m1"), from: bob), now: 0)
        let second = router.admit(inbound(frame("m1"), from: bob), now: 0)
        #expect(first == .new)
        #expect(second == .duplicate)
        #expect(router.counters.admitted == 1 && router.counters.deduplicated == 1)
    }

    @Test func aRelayGoesToEveryOtherNeighbourWithOneMoreHop() {
        var router = Router()
        let (_, immediate) = handle(&router, frame("m1"), from: bob, neighbors: [bob, carol])
        let fired = router.fireDue(now: 0, neighbors: [bob, carol])
        #expect(immediate.isEmpty)
        #expect(fired.map(\.to) == [carol])
        #expect(fired.map(\.wire.hops) == [1])
        #expect(router.counters.relayed == 1)
    }

    @Test func addressedDMsFloodLikeRoomPosts() {
        // DMs have no routing table: a DM must flood, or it could never reach a recipient out of direct range.
        var router = Router()
        _ = handle(&router, frame("dm1", recipient: zed), from: bob, neighbors: [bob, carol])
        #expect(router.fireDue(now: 0, neighbors: [bob, carol]).map(\.to) == [carol])
    }

    @Test func aFrameIsNotRelayedOnceItsHopsReachItsTTL() {
        var router = Router()
        _ = handle(&router, frame("m1", ttl: 3, hops: 3), from: bob, neighbors: [bob, carol])
        #expect(router.nextDeadline == nil)
        #expect(router.fireDue(now: 0, neighbors: [bob, carol]).isEmpty)
    }

    @Test func aForgedOversizedTTLIsCappedOnRelay() {
        var router = Router()
        _ = handle(&router, frame("m1", ttl: .max), from: bob, neighbors: [bob, carol])
        let relayed = router.fireDue(now: 0, neighbors: [bob, carol]).map(\.wire)
        #expect(relayed.map(\.ttl) == [WireEnvelope.defaultTTL])
        #expect(relayed.map(\.hops) == [1])
    }

    @Test func aForgedTTLStopsAtTheLocalCap() {
        var router = Router()
        _ = handle(&router, frame("m1", ttl: .max, hops: WireEnvelope.defaultTTL), from: bob, neighbors: [bob, carol])
        #expect(router.fireDue(now: 0, neighbors: [bob, carol]).isEmpty)
    }

    @Test func aPointToPointFrameIsDeliveredButNeverFlooded() {
        var router = Router()
        let (admission, immediate) = handle(&router, frame("req1", relay: false), from: bob, neighbors: [bob, carol])
        #expect(admission == .new)
        #expect(immediate.isEmpty)
        #expect(router.nextDeadline == nil)
    }

    @Test func aPointToPointDMFormFrameIsHandedToItsLinkedAddressee() {
        var router = Router()
        let (_, immediate) = handle(&router, frame("tick1", recipient: zed, relay: false), from: bob, neighbors: [bob, zed])
        #expect(immediate.map(\.to) == [zed])
        #expect(immediate.map(\.wire.hops) == [1], "the hop is counted, as a relay counts one")
        #expect(immediate.map(\.wire.relay) == [false], "and it goes no further at the addressee")
        #expect(router.counters.handedOn == 1)
    }

    @Test func aPointToPointFrameIsNeverHandedBackWhereItCameFrom() {
        var router = Router()
        let (_, immediate) = handle(&router, frame("tick1", recipient: bob, relay: false), from: bob, neighbors: [bob])
        #expect(immediate.isEmpty)
    }

    @Test func nothingIsHandedOnWithoutALiveLink() {
        var router = Router()
        let (_, immediate) = handle(&router, frame("tick1", recipient: zed, relay: false), from: bob, neighbors: [bob, carol])
        #expect(immediate.isEmpty)
    }

    @Test func onlyDMFormChatIsHandedOn() {
        var router = Router()
        let group = GroupInfo(id: "g", members: [zed.string], createdBy: "a")
        let frames = [
            frame("t1", recipient: zed, relay: false, type: .typing),
            frame("k1", relay: false, type: .keyRequest),
            frame("g1", recipient: zed, relay: false, group: group),
        ]
        let sends = frames.flatMap { handle(&router, $0, from: bob, neighbors: [bob, zed]).1 }
        #expect(sends.isEmpty)
    }

    @Test func aHandOnStopsAtTheLocalHopCap() {
        var router = Router()
        let late = frame("tick1", ttl: .max, hops: WireEnvelope.defaultTTL, recipient: zed, relay: false)
        #expect(handle(&router, late, from: bob, neighbors: [bob, zed]).1.isEmpty)
    }

    @Test func aDuplicateFromASecondNeighbourCancelsThePendingRelay() {
        var router = Router()
        _ = handle(&router, frame("m1"), from: bob, neighbors: [bob, carol, dave], jitter: 100, now: 0)
        let overheard = router.admit(inbound(frame("m1"), from: carol), now: 40)
        #expect(overheard == .duplicate)
        #expect(router.fireDue(now: 100, neighbors: [bob, carol, dave]).isEmpty)
        #expect(router.counters.suppressed == 1)
        #expect(router.counters.relayed == 0)
    }

    @Test func aDuplicateFromTheSameNeighbourIsNotAnOverhear() {
        // The link-up push, then the custody re-serve of the same frame from the same peer.
        var router = Router()
        _ = handle(&router, frame("m1"), from: bob, neighbors: [bob, carol, dave], jitter: 100, now: 0)
        _ = router.admit(inbound(frame("m1"), from: bob), now: 40)
        let fired = router.fireDue(now: 100, neighbors: [bob, carol, dave])
        #expect(Set(fired.map(\.to)) == [carol, dave])
        #expect(router.counters.suppressed == 0)
    }

    @Test func aRelayWaitsOutItsJitterThenSkipsEverySource() {
        var router = Router()
        _ = handle(&router, frame("m1"), from: bob, neighbors: [bob, carol, dave], jitter: 100, now: 0)
        #expect(router.nextDeadline == 100)
        #expect(router.fireDue(now: 99, neighbors: [bob, carol, dave]).isEmpty)
        let fired = router.fireDue(now: 100, neighbors: [bob, carol, dave])
        #expect(Set(fired.map(\.to)) == [carol, dave])
        #expect(fired.allSatisfy { $0.wire.hops == 1 })
        #expect(router.nextDeadline == nil)
    }

    @Test func aRelayGoesToTheNeighboursLinkedWhenItFires() {
        var router = Router()
        _ = handle(&router, frame("m1"), from: bob, neighbors: [bob, carol], jitter: 50, now: 0)
        #expect(router.fireDue(now: 50, neighbors: [bob, dave]).map(\.to) == [dave])
    }

    @Test func relaysFireOldestFirst() {
        var router = Router()
        _ = handle(&router, frame("late"), from: bob, neighbors: [bob, carol], jitter: 90, now: 0)
        _ = handle(&router, frame("early"), from: bob, neighbors: [bob, carol], jitter: 10, now: 0)
        let ids = router.fireDue(now: 100, neighbors: [bob, carol]).compactMap { try? RelayEnvelope(decoding: $0.wire.signed).id }
        #expect(ids == ["early", "late"])
    }

    @Test func aRoomPostOverTheBudgetIsRefusedUnmarked() {
        var router = Router(budget: IngressBudget(burst: 1, perMinute: 60))
        let first = handle(&router, frame("m1"), from: bob, neighbors: [bob, carol])
        let second = handle(&router, frame("m2"), from: bob, neighbors: [bob, carol])
        #expect(first.0 == .new)
        #expect(second.0 == .refused)
        #expect(router.counters.refused == 1)
        // Never marked seen, so the custody re-serve brings it in once the bucket refills: a delay, not a veto.
        let later = handle(&router, frame("m2"), from: bob, neighbors: [bob, carol], now: 1000)
        #expect(later.0 == .new)
    }

    @Test func duplicatesAndAddressedFramesAreNotMetered() {
        var router = Router(budget: IngressBudget(burst: 1, perMinute: 0))
        let admissions = [
            handle(&router, frame("m1"), from: bob, neighbors: [bob, carol]).0,
            handle(&router, frame("m1"), from: bob, neighbors: [bob, carol]).0,
            handle(&router, frame("m1"), from: carol, neighbors: [bob, carol]).0,
            handle(&router, frame("dm1", recipient: zed), from: bob, neighbors: [bob, carol]).0,
        ]
        #expect(admissions == [.new, .duplicate, .duplicate, .new])
        #expect(router.counters.refused == 0)
    }

    @Test func ourOwnFrameEchoesAsADuplicate() {
        var router = Router()
        router.markOwn("mine", now: 0)
        let echo = router.admit(inbound(frame("mine"), from: bob), now: 5)
        #expect(echo == .duplicate)
    }

    @Test func cancelAllDropsEveryPendingRelay() {
        var router = Router()
        _ = handle(&router, frame("m1"), from: bob, neighbors: [bob, carol], jitter: 50)
        router.cancelAll()
        #expect(router.nextDeadline == nil)
        #expect(router.fireDue(now: 100, neighbors: [bob, carol]).isEmpty)
    }

    @Test func reopenLetsOneMoreCopyIn() {
        var router = Router()
        _ = router.admit(inbound(frame("m1"), from: bob), now: 0)
        let reopened = router.reopen("m1", now: 1)
        let again = router.admit(inbound(frame("m1"), from: bob), now: 2)
        #expect(reopened)
        #expect(again == .new)
    }

    @Test func aCraftedIdThatSwiftCallsEqualIsStillNew() {
        // The Kelvin sign is "K" to Swift's String ==, and a different frame to Android.
        var router = Router()
        _ = router.admit(inbound(frame("idK"), from: bob), now: 0)
        let crafted = router.admit(inbound(frame("id\u{212A}"), from: bob), now: 0)
        #expect(crafted == .new)
    }

    @Test func aHigherThresholdNeedsMoreDistinctNeighbours() {
        var router = Router(configuration: Router.Configuration(suppressThreshold: 3))
        _ = handle(&router, frame("m1"), from: bob, neighbors: [bob, carol, dave, zed], jitter: 100)
        _ = router.admit(inbound(frame("m1"), from: carol), now: 10)
        #expect(router.counters.suppressed == 0, "two of three")
        _ = router.admit(inbound(frame("m1"), from: dave), now: 20)
        #expect(router.counters.suppressed == 1)
        #expect(router.fireDue(now: 100, neighbors: [bob, carol, dave, zed]).isEmpty)
    }
}
