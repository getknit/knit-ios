import KnitMesh
import KnitStore
import KnitWire
import Testing

/// When a peer is dialed, in this port's two rules beside Android's (ADR 2026-09.6es2, amended 2026-09-29): the link
/// layer wakes when a peer's dwell ends between its adverts, and never dials a peer quiet for more than 8 s.
@Suite struct LinkDwellTests {
    private let low = LinkRig.low
    private let high = LinkRig.high

    @Test func aPeerNotHeardForEightSecondsIsNotDialedAgain() throws {
        // The Pixel 7 probe on 2026-09-29: a phone that had left was dialed two or three times while its sighting
        // lingered, and each timeout doubled its backoff, up to 80 s.
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        _ = rig.handle(.dialFailed(try #require(rig.radio.dials.first?.channel)))
        _ = rig.advance(12_001)
        #expect(rig.radio.dials.count == 1, "its backoff has run out, but it has been quiet since the dial")
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.radio.dials.count == 1, "back after a gap over 8 s, it starts a new dwell")
    }

    @Test func aPeerIsDialedWhenItsDwellEndsBetweenItsAdverts() {
        let rig = LinkRig(local: high)
        let start = rig.clock.monotonicMilliseconds()
        rig.hear(low)
        #expect(rig.links.nextDeadline == start + 12_000)
        _ = rig.advance(6999)
        #expect(rig.radio.dials.isEmpty)
        _ = rig.advance(1)
        #expect(rig.radio.dials.map(\.address) == [RadioAddress("addr-\(low)")], "on the timer, with no advert then")
    }

    @Test func noWakeForAPeerThatWillBeQuietTooLongWhenItsDwellEnds() {
        let rig = LinkRig(local: high)
        let start = rig.clock.monotonicMilliseconds()
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.links.nextDeadline == nil, "heard once, it would be 12 s quiet by then")
        rig.clock.advance(3999)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.links.nextDeadline == nil, "8.001 s quiet by then")
        rig.clock.advance(1)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.links.nextDeadline == start + 12_000, "8 s quiet still counts as heard")
    }

    @Test func noWakeForAPeerWeWouldNotDial() {
        let weak = LinkRig(local: high)
        weak.hear(low, rssi: -95)
        #expect(weak.links.nextDeadline == nil, "below the floor")
        let dialsUs = LinkRig(local: low, advertisesServiceData: false)
        dialsUs.hear(high)
        #expect(dialsUs.links.nextDeadline == nil, "it reads our GATT payload and dials us")
        let refused = LinkRig(local: high)
        _ = refused.links.refuse(low)
        refused.hear(low)
        #expect(refused.links.nextDeadline == nil, "refused")
        let linked = LinkRig(local: high)
        _ = linked.accept(low, on: ChannelID(40))
        linked.hear(low)
        #expect(linked.links.neighbors.map(\.nodeId) == [low])
        #expect(linked.links.nextDeadline == nil, "already linked")
    }

    @Test func aPeerBackingOffWakesForItsBackoffNotItsDwell() throws {
        let backoff = ConnectBackoff.Configuration(baseMilliseconds: 30_000, jitterFraction: 0)
        let rig = LinkRig(local: high, configuration: LinkManager.Configuration(backoff: backoff))
        rig.sightToPromotion(low)
        let failedAt = rig.clock.monotonicMilliseconds()
        _ = rig.handle(.dialFailed(try #require(rig.radio.dials.first?.channel)))
        rig.clock.advance(9000)
        rig.hear(low)
        #expect(rig.links.nextDeadline == failedAt + 30_000, "its new dwell ends 21 s after the failure, still backing off")
    }

    @Test(.timeLimit(.minutes(1))) func theMeshActorsTimerDialsWhenADwellEnds() async {
        let alice = TestPeer(seed: 1)
        let radio = FakeRadio(advertisesServiceData: false)
        let clock = ManualClock(wall: EngineFixture.start, monotonic: 1000)
        let mesh = Mesh(
            identity: alice.keys,
            deviceTag: nil,
            stores: MeshStores.inMemory(),
            radio: radio,
            clock: clock,
            random: SeededGenerator(seed: 11),
            log: RecordingLog()
        )
        await mesh.start()
        // No flag: Android 2.7 cannot see this radio, so it dials whatever the order.
        let advert = AdvertPayload(capabilities: 0xFFF, nodeId: TestPeer(seed: 2).nodeId, digestCue: 0, psm: 0x80, flags: 0)
        let sighting = RadioSighting(address: RadioAddress("bob"), advert: advert, rssi: -50)
        await mesh.process(.sighted(sighting))
        clock.advance(5000)
        await mesh.process(.sighted(sighting))
        #expect(radio.dials.isEmpty)
        var activity = radio.activity.makeAsyncIterator()
        // The advert's timer, due at 2.5 s, may still be firing. Moved past 13 s under it, the clock would end the dwell
        // between the link manager's advance and its next deadline, and no timer would be set for it.
        await clock.parked(until: 13_000)
        clock.advance(7000)
        var dialed: RadioAddress?
        while dialed == nil, let next = await activity.next() {
            if case .dialed(let dial) = next {
                dialed = dial.address
            }
        }
        #expect(dialed == RadioAddress("bob"), "12 s after the first advert, with none since the second")
    }
}
