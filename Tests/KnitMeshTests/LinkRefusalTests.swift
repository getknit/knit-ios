import KnitMesh
import KnitWire
import Testing

/// Refusing a peer both ways, the rig's `deny-link`: no dial, no admission, and its links cut.
@Suite struct LinkRefusalTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high

    @Test func aRefusedPeerIsNeverDialedUntilItIsPermitted() {
        let rig = LinkRig(local: high)
        _ = rig.links.refuse(low)
        rig.sightToPromotion(low)
        #expect(rig.radio.dials.isEmpty)
        _ = rig.links.permit(low)
        #expect(rig.radio.dials.map(\.address) == [RadioAddress("addr-\(low)")], "still present and dwelled, so dialed at once")
    }

    @Test func aRefusedPeerThatDialsUsIsClosedAtItsHello() {
        let rig = LinkRig(local: low)
        _ = rig.links.refuse(high)
        let events = rig.accept(high, on: ChannelID(40))
        #expect(events.isEmpty)
        #expect(rig.radio.closed == [ChannelID(40)])
        #expect(rig.radio.records(on: ChannelID(40)).isEmpty, "no HELLO back")
    }

    @Test func refusingALinkedPeerTakesItsLinkDownAndLeavesTheOthers() throws {
        let rig = LinkRig(local: high)
        let lowLink = try rig.link(low)
        let middleLink = try rig.link(middle)
        let events = rig.links.refuse(low)
        #expect(events == [.down(low)])
        #expect(rig.radio.closed == [lowLink])
        #expect(rig.links.neighbors.map(\.nodeId) == [middle])
        #expect(!rig.radio.closed.contains(middleLink))
    }

    @Test func refusingCancelsADialInFlightWithoutBackingOff() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let dial = try #require(rig.radio.dials.last?.channel)
        #expect(rig.links.refuse(low).isEmpty)
        #expect(rig.radio.closed == [dial])
        #expect(rig.links.nextDeadline == nil, "no connect watchdog and no backoff left behind")
    }

    @Test func aChannelStillWaitingForItsHelloIsLeftAlone() {
        let rig = LinkRig(local: low)
        _ = rig.handle(.accepted(ChannelID(41)))
        _ = rig.links.refuse(high)
        #expect(rig.radio.closed.isEmpty, "nobody knows whose it is yet")
        let events = rig.handle(.received(ChannelID(41), LinkRig.helloRecord(middle)))
        #expect(events.first == .up(Neighbor(nodeId: middle, protocolVersion: 1, capabilities: 0xFFF)))
    }

    @Test func refusingClosesEveryChannelThePeerHasInOrder() throws {
        // A dial still in flight when the same peer, no longer sighted, dials us: two channels to one peer.
        var configuration = LinkManager.Configuration()
        configuration.connectTimeoutMilliseconds = 200_000
        let rig = LinkRig(local: high, configuration: configuration)
        rig.sightToPromotion(low)
        let dial = try #require(rig.radio.dials.last?.channel)
        _ = rig.advance(95_000)
        let accepted = ChannelID(77)
        #expect(rig.accept(low, on: accepted).first == .up(Neighbor(nodeId: low, protocolVersion: 1, capabilities: 0xFFF)))
        #expect(rig.links.refuse(low) == [.down(low)])
        #expect(rig.radio.closed == [dial, accepted])
    }
}
