import KnitMesh
import KnitWire
import Testing

/// The head start (interop-audit finding AND-2): at the front, a radio that serves the doorbell dials a flagged peer
/// above it once the ordinary 12 s dwell and a 12 s head start have passed, one such dial at a time, strongest first.
/// Admission keeps the order, and a refusal is an ordinary failed dial.
@Suite struct LinkHeadStartTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high
    private let flagged = AdvertPayload.dialsGattPeersFlag

    /// An iPhone at the front: no service data, and the doorbell served.
    private func iPhone(_ local: NodeId, background: Bool = false) -> LinkRig {
        LinkRig(local: local, advertisesServiceData: false, servesDoorbell: true, background: background)
    }

    private func headStartLines(_ rig: LinkRig) -> [String] {
        rig.log.all.filter { $0.contains("link head start over for") }
    }

    @Test func aFlaggedPeerAboveIsDialedAtTwentyFourSecondsOfDwellAndNotBefore() {
        let rig = iPhone(low)
        let first = rig.clock.monotonicMilliseconds()
        rig.sightToPromotion(high)
        #expect(rig.radio.dials.isEmpty, "not at the ordinary 12 s")
        rig.advance(10_000, hearing: high)
        _ = rig.advance(1999)
        #expect(rig.clock.monotonicMilliseconds() - first == 23_999)
        #expect(rig.radio.dials.isEmpty, "not before 24 s")
        _ = rig.advance(1)
        #expect(rig.radio.dials.map(\.address) == [RadioAddress("addr-\(high)")])
        #expect(headStartLines(rig) == ["info link head start over for \(high) (dwell=24000ms rssi=-50dBm)"])
        let lines = rig.log.all
        let marked = lines.firstIndex { $0.contains("link head start over for \(high)") }
        let dialed = lines.firstIndex { $0.contains("link dialing \(high)") }
        #expect(marked.map { $0 + 1 } == dialed, "the head start's line comes right before the dial's own")
    }

    @Test func theManagerWakesWhenAHeadStartEndsWithNothingHeard() {
        let rig = iPhone(low)
        let first = rig.clock.monotonicMilliseconds()
        // Heard every two seconds for 20 s, then quiet: 24 s finds it heard 4 s ago, inside the 12 s limit.
        for step in 0...10 {
            if step > 0 {
                rig.clock.advance(2000)
            }
            _ = rig.handle(.sighted(LinkRig.sighting(high)))
        }
        #expect(rig.links.nextDeadline == first + 24_000)
        rig.run(until: first + 24_000)
        #expect(rig.radio.dials.count == 1)
    }

    @Test func oneHeadStartDialAtATimeTheStrongestFirst() throws {
        let rig = iPhone(low)
        for step in 0...14 {
            if step > 0 {
                rig.clock.advance(2000)
            }
            _ = rig.handle(.sighted(LinkRig.sighting(middle, rssi: -60)))
            _ = rig.handle(.sighted(LinkRig.sighting(high, rssi: -50)))
        }
        #expect(rig.radio.dials.map(\.address) == [RadioAddress("addr-\(high)")], "the stronger alone")
        let id = try #require(rig.radio.dials.first?.channel)
        rig.advance(4000, hearing: middle)
        #expect(rig.radio.dials.count == 1, "the other waits while a head-start dial is open")
        _ = rig.handle(.dialFailed(id))
        #expect(rig.radio.dials.map(\.address).last == RadioAddress("addr-\(middle)"), "then the next is dialed")
        #expect(headStartLines(rig).count == 2)
    }

    @Test func aRefusalBacksOffAndTheNextAttemptFollowsTheBackoff() throws {
        let rig = iPhone(low)
        rig.sightToPromotion(high)
        rig.advance(12_000, hearing: high)
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.connected(id))
        // Android closes a dialer it sighted without a HELLO reply (`BleAdmissionPolicy.kt:51`).
        _ = rig.handle(.closed(id))
        #expect(rig.links.neighbors.isEmpty)
        rig.advance(7999, hearing: high)
        #expect(rig.radio.dials.count == 1, "10 s ± 20 % is at least 8 s")
        rig.advance(4002, hearing: high)
        #expect(rig.radio.dials.count == 2, "and at most 12 s, with no fresh head start")
        #expect(headStartLines(rig).count == 2)
    }

    @Test func aHeadStartDialsHelloAsksToBeRung() throws {
        let rig = iPhone(low)
        rig.sightToPromotion(high)
        rig.advance(12_000, hearing: high)
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.connected(id))
        #expect(rig.radio.records(on: id) == [LinkRig.ourHello(low, servesDoorbell: true)], "caps 300f")
        let events = rig.handle(.received(id, LinkRig.helloRecord(high)))
        #expect(events == [.up(Neighbor(nodeId: high, protocolVersion: 1, capabilities: 0xFFF))])
    }

    @Test func aRadioThatServesNoDoorbellGivesNoHeadStart() {
        // A head-start link is the iPhone's to open at 720 ms, and only Android's doorbell lookup asks for 5 s.
        let rig = LinkRig(local: low, advertisesServiceData: false, servesDoorbell: false)
        rig.sightToPromotion(high)
        rig.advance(60_000, hearing: high)
        #expect(rig.radio.dials.isEmpty)
        #expect(headStartLines(rig).isEmpty)
    }

    @Test func anUnflaggedPeerIsDialedAtTheOrdinaryDwell() {
        let rig = iPhone(low)
        rig.sightToPromotion(high, flags: 0)
        #expect(rig.radio.dials.count == 1)
        #expect(headStartLines(rig).isEmpty)
    }

    @Test func aLargerIdIPhoneIsUnchanged() {
        let rig = iPhone(high)
        rig.sightToPromotion(low, flags: flagged)
        #expect(rig.radio.dials.count == 1, "the larger id dials at 12 s")
        #expect(headStartLines(rig).isEmpty)
    }

    @Test func seekingInTheBackgroundIsUnchanged() {
        let rig = iPhone(low, background: true)
        _ = rig.handle(.sighted(LinkRig.sighting(high)))
        #expect(rig.radio.dials.count == 1, "one sighting is enough")
        #expect(headStartLines(rig).isEmpty)
    }

    @Test func aLinkedIPhoneInTheBackgroundGivesNoHeadStart() {
        let rig = iPhone(low, background: true)
        _ = rig.accept(middle, on: ChannelID(100))
        #expect(!rig.links.isSeeking)
        rig.sightToPromotion(high)
        rig.advance(30_000, hearing: high)
        #expect(rig.radio.dials.isEmpty)
    }

    @Test func admissionKeepsTheOrder() {
        // A flagged peer above us that dials while we wait on its head start is admitted, as before.
        let rig = iPhone(low)
        rig.sightToPromotion(high)
        let events = rig.accept(high, on: ChannelID(100))
        #expect(events == [.up(Neighbor(nodeId: high, protocolVersion: 1, capabilities: 0xFFF))])
        rig.advance(30_000, hearing: high)
        #expect(rig.radio.dials.isEmpty, "linked, so never dialed")
    }
}
