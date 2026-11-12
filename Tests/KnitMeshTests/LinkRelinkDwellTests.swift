import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// The relink window in promotion (``LinkManager/withRelinkDwell(_:now:)``): a peer ours to dial whose proven link the
/// radio closed lately is dialed on its first sighting once the close's backoff ends, with no 12 s dwell. After the
/// iPhone's address change the reader above it relinked by its own dial 18 to 59 s after the drop, each read waiting out a
/// dwell the 8 s gap reset had restarted (`.agents/context/linux-peer.md`, "Its trial did not reach the window").
@Suite struct LinkRelinkDwellTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high

    /// `peer` dials `rig` unsighted on `id`, proves itself, is sighted once on the link, and 5 s later the radio closes the
    /// link: the window opens, and the close books a backoff, by whose end the sighting is past the 12 s silence limit.
    /// Answers when the radio closed it.
    @discardableResult
    private func closedByTheRadio(_ rig: LinkRig, _ peer: NodeId, on id: ChannelID = ChannelID(100)) throws -> Int64 {
        let (hello, _) = rig.acceptProving(peer, on: id)
        _ = try rig.proveDialer(peer, on: id, hello: hello)
        _ = rig.handle(.sighted(LinkRig.sighting(peer)))
        _ = rig.advance(5000)
        #expect(rig.handle(.closed(id)) == [.down(peer)])
        #expect(rig.relinkOpen(for: peer))
        return rig.clock.monotonicMilliseconds()
    }

    private func dials(_ rig: LinkRig, _ peer: NodeId) -> Int {
        rig.radio.dials.filter { $0.address == RadioAddress("addr-\(peer)") }.count
    }

    private func backoffDue(_ rig: LinkRig, _ peer: NodeId) throws -> Int64 {
        try #require(rig.links.backoffs[.peer(.node(peer))]?.nextAt)
    }

    @Test func pastTheBackoffTheFirstSightingAfterAGapDials() throws {
        let rig = LinkRig(local: high)
        let closed = try closedByTheRadio(rig, low)
        #expect(try backoffDue(rig, low) - closed <= 12_000, "the close's backoff, 8 to 12 s")
        rig.run(until: closed + 15_000)
        #expect(dials(rig, low) == 0, "nothing heard, nothing dialed")
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(dials(rig, low) == 1, "dialed on the sighting, its dwell restarted by the 15 s gap")
        #expect(rig.log.all.contains { $0.hasPrefix("info link dialing \(low) on ch") })
        #expect(rig.links.dwellDue(now: rig.clock.monotonicMilliseconds()) == nil)
    }

    @Test func insideTheBackoffTheSightingWaitsForTheBackoffsDeadlineThenDials() throws {
        let rig = LinkRig(local: high)
        let closed = try closedByTheRadio(rig, low)
        _ = rig.advance(5000)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(dials(rig, low) == 0, "the close's backoff still holds")
        let due = try backoffDue(rig, low)
        #expect(due > rig.clock.monotonicMilliseconds())
        #expect(rig.links.dwellDue(now: rig.clock.monotonicMilliseconds()) == nil, "a backing-off peer waits for its backoff's deadline")
        #expect(rig.links.nextDeadline == due)
        rig.run(until: due)
        #expect(dials(rig, low) == 1, "dialed at the backoff's wake, heard \(due - closed - 5000) ms before")
        #expect(rig.clock.monotonicMilliseconds() - closed < 30_000)
    }

    /// A sighting from before the close may be the iPhone's dead pre-change address: inside the silence limit at the
    /// backoff's wake it still dials nothing, and the first sighting after the close dials.
    @Test func aSightingFromBeforeTheCloseIsNoRelinkSighting() throws {
        let rig = LinkRig(local: high)
        let (hello, _) = rig.acceptProving(low, on: ChannelID(100))
        _ = try rig.proveDialer(low, on: ChannelID(100), hello: hello)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        _ = rig.advance(1000)
        #expect(rig.handle(.closed(ChannelID(100))) == [.down(low)])
        let closed = rig.clock.monotonicMilliseconds()
        let due = try backoffDue(rig, low)
        #expect(due - closed + 1000 <= 12_000, "the old sighting is inside the silence limit at the wake")
        rig.run(until: due)
        #expect(rig.clock.monotonicMilliseconds() == due)
        #expect(dials(rig, low) == 0, "no dial to the address heard before the close")
        _ = rig.advance(1)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(dials(rig, low) == 1, "the first sighting since the close dials")
    }

    @Test func outsideTheWindowTheDwellAndItsWakeComeBack() throws {
        let rig = LinkRig(local: high)
        let closed = try closedByTheRadio(rig, low)
        rig.run(until: closed + 31_000)
        #expect(!rig.relinkOpen(for: low))
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        let heard = rig.clock.monotonicMilliseconds()
        #expect(dials(rig, low) == 0)
        #expect(rig.links.dwellDue(now: heard) == heard + 12_000)
        #expect(rig.links.nextDeadline == heard + 12_000)
        rig.run(until: heard + 11_999)
        #expect(dials(rig, low) == 0, "not before the 12 s dwell")
        rig.run(until: heard + 12_000)
        #expect(dials(rig, low) == 1)
    }

    @Test func afterOurOwnEvictionTheDwellStillHolds() throws {
        let configuration = LinkManager.Configuration(promotion: PromotionPolicy.Configuration(maxLinks: 1))
        let rig = LinkRig(local: high, configuration: configuration)
        let (hello, _) = rig.acceptProving(low, on: ChannelID(100))
        _ = try rig.proveDialer(low, on: ChannelID(100), hello: hello)
        rig.clock.advance(20_000)
        rig.sightToPromotion(middle, rssi: -60)
        #expect(rig.said("link evicting \(low)"))
        _ = rig.handle(.closed(ChannelID(100)))
        #expect(!rig.relinkOpen(for: low))
        _ = rig.advance(9000)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        let heard = rig.clock.monotonicMilliseconds()
        #expect(dials(rig, low) == 0, "an eviction of ours opens no window, so the dwell holds")
        #expect(rig.links.dwellDue(now: heard) == heard + 12_000)
    }

    @Test func aHeadStartPeerWithItsWindowOpenStillWaitsTwentyFourSeconds() throws {
        let rig = LinkRig(local: low, advertisesServiceData: false, servesDoorbell: true)
        let closed = try closedByTheRadio(rig, high)
        rig.run(until: closed + 15_000)
        let first = rig.clock.monotonicMilliseconds()
        rig.sightToPromotion(high)
        #expect(rig.relinkOpen(for: high))
        #expect(dials(rig, high) == 0, "not at the ordinary 12 s")
        rig.advance(10_000, hearing: high)
        _ = rig.advance(1999)
        #expect(rig.clock.monotonicMilliseconds() - first == 23_999)
        #expect(dials(rig, high) == 0, "not before 24 s, window or none")
        _ = rig.advance(1)
        #expect(dials(rig, high) == 1)
        #expect(rig.said("link head start over for \(high) (dwell=24000ms rssi=-50dBm)"))
    }

    /// A relinking peer with no free slot is promotable and not dialed: its dwell is met, so no wake comes due for it, and
    /// the manager never spins on one.
    @Test func aRelinkingPeerWithNoSlotNamesNoWake() throws {
        let configuration = LinkManager.Configuration(promotion: PromotionPolicy.Configuration(maxLinks: 1))
        let rig = LinkRig(local: high, configuration: configuration)
        let closed = try closedByTheRadio(rig, low)
        let (hello, _) = rig.acceptProving(middle, on: ChannelID(101))
        _ = try rig.proveDialer(middle, on: ChannelID(101), hello: hello)
        rig.run(until: closed + 15_000)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        let now = rig.clock.monotonicMilliseconds()
        #expect(rig.relinkOpen(for: low))
        #expect(dials(rig, low) == 0, "the budget is full")
        #expect(rig.links.dwellDue(now: now) == nil)
        #expect(rig.links.nextDeadline.map { $0 > now } ?? true, "no deadline due now")
    }
}
