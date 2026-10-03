import KnitMesh
import KnitWire
import Testing

/// Whom a seeking node dials (ADR 2026-10.mueg): a peer on its first sighting, whatever the order, since iOS resumes a
/// suspended iPhone for about 10 s and no peer can find it there. Admission keeps the order, and so settles a
/// cross-dial as at the front.
@Suite struct LinkSeekDialTests {
    private let low = LinkRig.low
    private let high = LinkRig.high

    @Test func whileSeekingOneSightingIsDialedAtOnce() {
        let rig = LinkRig(local: high, advertisesServiceData: false, background: true)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.radio.dials.map(\.address) == [RadioAddress("addr-\(low)")])
        let front = LinkRig(local: high, advertisesServiceData: false)
        _ = front.handle(.sighted(LinkRig.sighting(low)))
        #expect(front.radio.dials.isEmpty, "at the front a peer dwells 12 s first")
    }

    @Test func seekingTurningOnDialsAPeerHeardMomentsAgo() {
        let rig = LinkRig(local: high, advertisesServiceData: false)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        rig.clock.advance(3000)
        _ = rig.links.setInBackground(true)
        #expect(rig.radio.dials.map(\.address) == [RadioAddress("addr-\(low)")])
    }

    @Test func whileSeekingTheFloorAndTheSilenceLimitStillHold() {
        let weak = LinkRig(local: high, advertisesServiceData: false, background: true)
        _ = weak.handle(.sighted(LinkRig.sighting(low, rssi: -95)))
        #expect(weak.radio.dials.isEmpty, "below the floor")
        let quiet = LinkRig(local: high, advertisesServiceData: false)
        _ = quiet.handle(.sighted(LinkRig.sighting(low)))
        quiet.clock.advance(12_001)
        _ = quiet.links.setInBackground(true)
        #expect(quiet.radio.dials.isEmpty, "heard more than 12 s ago")
    }

    @Test func whileSeekingAPeerBackingOffWaitsItOut() throws {
        let backoff = ConnectBackoff.Configuration(baseMilliseconds: 30_000, jitterFraction: 0)
        let rig = LinkRig(
            local: high, advertisesServiceData: false, background: true, configuration: LinkManager.Configuration(backoff: backoff))
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        let failedAt = rig.clock.monotonicMilliseconds()
        _ = rig.handle(.dialFailed(try #require(rig.radio.dials.first?.channel)))
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.radio.dials.count == 1)
        #expect(rig.links.nextDeadline == failedAt + 30_000, "its backoff's end, and no dwell to wake for")
        rig.clock.advance(30_000)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.radio.dials.count == 2)
    }

    @Test func whileSeekingAPeerThatWouldDialUsIsDialedWhateverTheOrder() {
        // The larger peer reads our GATT payload at the front, but no one reads the overflow area of a backgrounded
        // iPhone, whatever its flag says.
        let rig = LinkRig(local: low, advertisesServiceData: false, background: true)
        _ = rig.handle(.sighted(LinkRig.sighting(high)))
        #expect(rig.radio.dials.map(\.address) == [RadioAddress("addr-\(high)")])
        let front = LinkRig(local: low, advertisesServiceData: false)
        front.sightToPromotion(high)
        #expect(front.radio.dials.isEmpty, "at the front it waits to be dialed")
    }

    @Test func aRadioThatAdvertisesServiceDataKeepsTheOrderWhileSeeking() {
        // Anyone can find a radio that advertises service data, so the smaller id still waits.
        let rig = LinkRig(local: low, advertisesServiceData: true, background: true)
        _ = rig.handle(.sighted(LinkRig.sighting(high)))
        #expect(rig.radio.dials.isEmpty)
    }

    @Test func whileSeekingAdmissionKeepsTheOrder() {
        // A cross-dial: the larger side refuses the smaller one it sighted, and the smaller admits the larger.
        let larger = LinkRig(local: high, advertisesServiceData: false, background: true)
        _ = larger.handle(.sighted(LinkRig.sighting(low)))
        #expect(larger.accept(low, on: ChannelID(100)).isEmpty)
        #expect(larger.radio.closed == [ChannelID(100)])
        let smaller = LinkRig(local: low, advertisesServiceData: false, background: true)
        _ = smaller.handle(.sighted(LinkRig.sighting(high)))
        #expect(smaller.accept(high, on: ChannelID(100)) == [.up(Neighbor(nodeId: high, protocolVersion: 1, capabilities: 0xFFF))])
    }

    @Test func aDeadlineThatPassedInSuspensionIsPutOffOnce() throws {
        let rig = LinkRig(local: high, advertisesServiceData: false, background: true)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.advance(14_000)
        #expect(rig.radio.closed.isEmpty, "the 12 s connect timeout came 2 s late")
        #expect(rig.log.all.contains("info link \(id) found its deadline 2000 ms late, and waits 3000 ms more"))
        _ = rig.advance(3000)
        #expect(rig.radio.closed == [id], "once only")
    }

    @Test func aDialThatOpenedInSuspensionCompletes() throws {
        // On resume the timer won the race to the actor; the dial's news came next.
        let rig = LinkRig(local: high, advertisesServiceData: false, background: true)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.advance(40_000)
        _ = rig.handle(.connected(id))
        let events = rig.handle(.received(id, LinkRig.helloRecord(low)))
        #expect(events.contains(.up(Neighbor(nodeId: low, protocolVersion: 1, capabilities: 0xFFF))))
    }

    @Test func aLateDeadlineAtTheFrontTimesOut() throws {
        let rig = LinkRig(local: high, advertisesServiceData: false)
        rig.sightToPromotion(low)
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.advance(14_000)
        #expect(rig.radio.closed == [id])
    }
}
