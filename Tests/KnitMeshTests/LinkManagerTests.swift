import KnitMesh
import KnitWire
import Testing

/// Advertising, who dials, the dialer's side of the handshake, backoff and the link budget
/// (`BluetoothMeshTransport.kt`).
@Suite struct LinkManagerTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high

    // MARK: Advertising

    @Test func theListenerIsAdvertisedWithOurIdItsPSMAndTheGATTFlag() {
        let rig = LinkRig(local: high)
        #expect(rig.radio.started)
        _ = rig.handle(.listening(psm: 0x81))
        let advert = rig.radio.advertised.last
        let expected = AdvertPayload(capabilities: .local, nodeId: high, digestCue: 0, psm: 0x81, flags: AdvertPayload.dialsGattPeersFlag)
        #expect(advert == expected)
        #expect(advert?.capabilities == 0xF)
    }

    @Test func aRadioThatCannotReadGATTPayloadsLeavesTheFlagClear() {
        let rig = LinkRig(local: high, dialsGattPeers: false)
        _ = rig.handle(.listening(psm: 0x81))
        #expect(rig.radio.advertised.last?.flags == 0)
    }

    @Test func aCustodyChangeReAdvertisesOnceTheBurstSettles() {
        let rig = LinkRig(local: high)
        _ = rig.handle(.listening(psm: 0x81))
        rig.links.updateDigestCue(7)
        rig.links.updateDigestCue(8)
        let settled: Int64 = 1000 + 1500
        #expect(rig.links.nextDeadline == settled)
        _ = rig.advance(1499)
        #expect(rig.radio.advertised.count == 1)
        _ = rig.advance(1)
        #expect(rig.radio.advertised.count == 2)
        #expect(rig.radio.advertised.last?.digestCue == 8)
    }

    // MARK: Who dials

    @Test func theLargerIdDialsASteadyCloseEnoughPeer() {
        let rig = LinkRig(local: high)
        for _ in 0..<6 {
            _ = rig.handle(.sighted(LinkRig.sighting(low)))
            rig.clock.advance(2000)
        }
        #expect(rig.radio.dials.isEmpty, "not before 12 s of dwell")
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.radio.dials.map(\.address) == [RadioAddress("addr-\(low)")])
        #expect(rig.radio.dials.map(\.psm) == [0x80])
    }

    @Test func aPeerBelowTheRSSIFloorIsNotDialed() {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low, rssi: -95)
        #expect(rig.radio.dials.isEmpty)
    }

    @Test func aPeerSightedWithGapsNeverDwellsLongEnough() {
        let rig = LinkRig(local: high)
        for _ in 0..<4 {
            _ = rig.handle(.sighted(LinkRig.sighting(low)))
            rig.clock.advance(9000)
        }
        #expect(rig.radio.dials.isEmpty, "a gap over 8 s restarts the dwell")
    }

    @Test func theSmallerIdWaitsForAPeerThatCanSeeIt() {
        let withFlag = LinkRig(local: low, advertisesServiceData: false)
        withFlag.sightToPromotion(high, flags: AdvertPayload.dialsGattPeersFlag)
        #expect(withFlag.radio.dials.isEmpty, "a peer that reads GATT payloads dials us")
        let serviceData = LinkRig(local: low, advertisesServiceData: true)
        serviceData.sightToPromotion(high, flags: 0)
        #expect(serviceData.radio.dials.isEmpty, "Android reads our service data, so it dials us")
    }

    @Test func aGATTOnlyRadioDialsAnAndroidPeerThatCannotSeeItWhateverTheOrder() {
        // Android 2.7 reads only service data, which an iPhone cannot advertise.
        let rig = LinkRig(local: low, advertisesServiceData: false)
        rig.sightToPromotion(high, flags: 0)
        #expect(rig.radio.dials.count == 1)
    }

    @Test func ourOwnAdvertIsIgnored() {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(high)
        #expect(rig.radio.dials.isEmpty)
        #expect(rig.links.sightings().isEmpty)
    }

    @Test func aPeerWithNoListenerIsNotDialed() {
        let rig = LinkRig(local: high)
        let closed = AdvertPayload(capabilities: 0xFFF, nodeId: low, digestCue: 0, psm: 0, flags: AdvertPayload.dialsGattPeersFlag)
        for _ in 0...6 {
            _ = rig.handle(.sighted(RadioSighting(address: RadioAddress("a"), advert: closed, rssi: -50)))
            rig.clock.advance(2000)
        }
        #expect(rig.radio.dials.isEmpty)
    }

    // MARK: The dialer's handshake

    @Test func aDialSendsOurHelloAndLinksOnAMatchingReply() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.connected(id))
        #expect(rig.radio.records(on: id) == [LinkRig.ourHello(high)])
        let events = rig.handle(.received(id, LinkRig.helloRecord(low)))
        #expect(events == [.up(Neighbor(nodeId: low, protocolVersion: 1, capabilities: 0xFFF))])
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
    }

    @Test func aReplyFromTheWrongPeerFailsTheDialAndBacksOff() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.connected(id))
        let events = rig.handle(.received(id, LinkRig.helloRecord(middle)))
        #expect(events.isEmpty)
        #expect(rig.radio.closed == [id])
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.radio.dials.count == 1, "backing off")
        rig.advance(12_001, hearing: low)
        #expect(rig.radio.dials.count == 2, "10 s ± 20 % later it tries again")
    }

    @Test func aDialThatNeverOpensTimesOutAfterTwelveSeconds() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.advance(11_999)
        #expect(rig.radio.closed.isEmpty)
        _ = rig.advance(1)
        #expect(rig.radio.closed == [id])
    }

    @Test func aReplyThatNeverComesTimesOutAfterFiveSeconds() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.connected(id))
        _ = rig.advance(5000)
        #expect(rig.radio.closed == [id])
        #expect(rig.links.neighbors.isEmpty)
    }

    @Test func aFailedDialBacksOffTheNextOne() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.dialFailed(id))
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.radio.dials.count == 1)
    }

    @Test func aClosedLinkGoesDownAndItsPeerBacksOff() throws {
        let rig = LinkRig(local: high)
        let id = try rig.link(low)
        let events = rig.handle(.closed(id))
        #expect(events == [.down(low)])
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.radio.dials.count == 1, "not straight back")
    }

    @Test func aLinkThatComesUpResetsTheBackoffStreak() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let failed = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.dialFailed(failed))
        rig.advance(12_001, hearing: low)
        let second = try #require(rig.radio.dials.last?.channel)
        _ = rig.handle(.connected(second))
        _ = rig.handle(.received(second, LinkRig.helloRecord(low)))
        _ = rig.handle(.closed(second))
        rig.advance(12_001, hearing: low)
        #expect(rig.radio.dials.count == 3, "a fresh streak waits 10 s again, not 20")
    }

    // MARK: Budget and lifecycle

    @Test func aClearlyStrongerCandidateReplacesTheWeakestOldLink() throws {
        let configuration = LinkManager.Configuration(promotion: PromotionPolicy.Configuration(maxLinks: 1))
        let rig = LinkRig(local: high, configuration: configuration)
        _ = try rig.link(low, rssi: -80)
        rig.clock.advance(20_000)
        let events = rig.sightToPromotion(middle, rssi: -60)
        #expect(events == [.down(low)])
        #expect(rig.radio.dials.last?.address == RadioAddress("addr-\(middle)"))
    }

    @Test func anUnsightedLinkScoresAtTheFloorNotAtMinus127() {
        let configuration = LinkManager.Configuration(promotion: PromotionPolicy.Configuration(maxLinks: 1))
        let rig = LinkRig(local: low, configuration: configuration)
        _ = rig.handle(.sighted(LinkRig.sighting(high, rssi: -95)))
        _ = rig.accept(high, on: ChannelID(100))
        _ = rig.accept(middle, on: ChannelID(101))
        #expect(rig.links.neighbors.count == 2, "a new link is held for 20 s even over budget")
        let events = rig.advance(20_000)
        #expect(events == [.down(high)], "the sighted −95 link is weaker than an unsighted one at −90")
    }

    @Test func aLinkWhosePeerWasSightedThenLostIsShedFirst() {
        // Only a peer never sighted during its link keeps the floor's score; one the scan saw and lost is gone.
        let configuration = LinkManager.Configuration(promotion: PromotionPolicy.Configuration(maxLinks: 1))
        let never = LinkRig(local: high, configuration: configuration)
        _ = never.accept(middle, on: ChannelID(100))
        _ = never.advance(100_000)
        #expect(never.sightToPromotion(low, rssi: -89).isEmpty, "−89 does not beat −90 by the 8 dB hysteresis")
        let lost = LinkRig(local: high, configuration: configuration)
        _ = lost.accept(middle, on: ChannelID(100))
        _ = lost.handle(.sighted(LinkRig.sighting(middle, rssi: -70)))
        _ = lost.advance(100_000)
        #expect(lost.sightToPromotion(low, rssi: -89) == [.down(middle)], "a lost peer scores −127")
    }

    @Test func switchingTheRadioOffTakesEveryLinkDown() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        _ = rig.handle(.sighted(LinkRig.sighting(middle)))
        let events = rig.handle(.state(.off))
        #expect(events == [.down(low)])
        #expect(rig.links.sightings().isEmpty)
        #expect(rig.handle(.state(.on)).isEmpty)
    }

    @Test func stopClosesEverythingAndStopsTheRadio() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        #expect(rig.links.stop() == [.down(low)])
        #expect(rig.radio.stopped)
        #expect(rig.links.stop().isEmpty)
        rig.sightToPromotion(low)
        #expect(rig.radio.dials.isEmpty, "nothing dials once stopped")
    }

    @Test func eventsForUnknownChannelsAreIgnored() {
        let rig = LinkRig(local: high)
        #expect(rig.handle(.connected(ChannelID(9))).isEmpty)
        #expect(rig.handle(.received(ChannelID(9), [1, 2])).isEmpty)
        #expect(rig.handle(.closed(ChannelID(9))).isEmpty)
        #expect(rig.handle(.dialFailed(ChannelID(9))).isEmpty)
    }
}
