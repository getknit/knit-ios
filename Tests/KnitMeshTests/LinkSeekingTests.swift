import KnitMesh
import KnitStore
import KnitWire
import Testing

/// When a node seeks peers: in the background, with no link, and wakes left (ADR 2026-10.mueg). The radio hears of a
/// change only, so a stale link's replacement or a burst of events never restarts its scan.
@Suite struct LinkSeekingTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high

    @Test func theFrontNeverSeeks() {
        let rig = LinkRig(local: low, advertisesServiceData: false)
        _ = rig.handle(.sighted(LinkRig.sighting(high)))
        #expect(rig.radio.seeks.isEmpty)
        #expect(!rig.links.isSeeking)
    }

    @Test func aBackgroundedNodeWithNoLinkSeeks() {
        let rig = LinkRig(local: low, advertisesServiceData: false, background: true)
        #expect(rig.radio.seeks == [true])
        #expect(rig.links.isSeeking)
        #expect(rig.links.seekSpells == 1)
        #expect(rig.log.all.contains("info link seeking on (background, no links)"))
    }

    @Test func hearingTheSameStateAgainChangesNothing() {
        let rig = LinkRig(local: low, advertisesServiceData: false, background: true)
        _ = rig.links.setInBackground(true)
        #expect(rig.radio.seeks == [true])
        #expect(rig.log.all.filter { $0 == "info link in the background" }.count == 1)
    }

    @Test func aLinkComingUpStopsSeeking() {
        let rig = LinkRig(local: low, advertisesServiceData: false, background: true)
        _ = rig.accept(high, on: ChannelID(40))
        #expect(rig.radio.seeks == [true, false])
        #expect(rig.log.all.contains("info link seeking off (link up)"))
    }

    @Test func seekingResumesOnlyWhenTheLastLinkDrops() {
        let rig = LinkRig(local: low, advertisesServiceData: false, background: true)
        _ = rig.accept(middle, on: ChannelID(40))
        _ = rig.accept(high, on: ChannelID(41))
        _ = rig.handle(.closed(ChannelID(40)))
        #expect(rig.radio.seeks == [true, false], "one link is still up")
        _ = rig.handle(.closed(ChannelID(41)))
        #expect(rig.radio.seeks == [true, false, true])
    }

    @Test func aLinkedNodeSeeksOnceItsLastLinkDropsInTheBackground() {
        let rig = LinkRig(local: low, advertisesServiceData: false)
        _ = rig.accept(high, on: ChannelID(40))
        _ = rig.links.setInBackground(true)
        #expect(rig.radio.seeks.isEmpty, "linked")
        _ = rig.handle(.closed(ChannelID(40)))
        #expect(rig.radio.seeks == [true])
    }

    @Test func comingToTheFrontStopsSeeking() {
        let rig = LinkRig(local: low, advertisesServiceData: false, background: true)
        _ = rig.links.setInBackground(false)
        #expect(rig.radio.seeks == [true, false])
        #expect(rig.log.all.contains("info link seeking off (front)"))
    }

    @Test func aStaleLinksReplacementLeavesSeekingAlone() {
        // admit() retires the old link and registers the new one: seeking must not flicker on between them.
        let rig = LinkRig(local: low, advertisesServiceData: false, background: true)
        _ = rig.accept(high, on: ChannelID(40))
        _ = rig.advance(30_000)
        _ = rig.accept(high, on: ChannelID(41))
        #expect(rig.links.neighbors.map(\.nodeId) == [high])
        #expect(rig.radio.closed == [ChannelID(40)], "the stale link was replaced")
        #expect(rig.radio.seeks == [true, false])
    }

    @Test func refusingTheLastLinkedPeerStartsSeeking() {
        let rig = LinkRig(local: low, advertisesServiceData: false, background: true)
        _ = rig.accept(high, on: ChannelID(40))
        _ = rig.links.refuse(high)
        #expect(rig.radio.seeks == [true, false, true])
    }

    @Test func stoppingStopsSeekingAndAStartInTheBackgroundSeeks() {
        let rig = LinkRig(local: low, advertisesServiceData: false, background: true)
        _ = rig.links.stop()
        #expect(rig.radio.seeks == [true, false])
        #expect(rig.log.all.contains("info link seeking off (stopped)"))
        rig.links.start()
        #expect(rig.radio.seeks == [true, false, true])
        #expect(rig.links.seekSpells == 2)
    }

    @Test func theBackgroundIsKeptWhileStopped() {
        let rig = LinkRig(local: low, advertisesServiceData: false)
        _ = rig.links.stop()
        _ = rig.links.setInBackground(true)
        #expect(rig.radio.seeks.isEmpty, "not running")
        rig.links.start()
        #expect(rig.radio.seeks == [true])
    }

    @Test func theRadioGoingOffWithALinkUpStartsSeeking() {
        // The link is gone with the radio. The radio keeps the request, and scans for the UUID once it is back on.
        let rig = LinkRig(local: low, advertisesServiceData: false, background: true)
        _ = rig.accept(high, on: ChannelID(40))
        _ = rig.handle(.state(.off))
        #expect(rig.links.neighbors.isEmpty)
        #expect(rig.radio.seeks == [true, false, true])
    }

    @Test(.timeLimit(.minutes(1))) func theMeshHearsTheBackgroundEvenWhileStopped() async {
        let radio = FakeRadio(advertisesServiceData: false)
        let mesh = Mesh(
            identity: TestPeer(seed: 1).keys,
            deviceTag: nil,
            stores: MeshStores.inMemory(),
            radio: radio,
            clock: ManualClock(wall: EngineFixture.start, monotonic: 1000),
            random: SeededGenerator(seed: 11),
            log: RecordingLog()
        )
        await mesh.setInBackground(true)
        #expect(radio.seeks.isEmpty, "not running yet")
        await mesh.start()
        #expect(radio.seeks == [true])
        #expect(await mesh.isSeeking)
        #expect(await mesh.seekSpells == 1)
        let bob = TestPeer(seed: 2).nodeId
        await mesh.process(.accepted(ChannelID(50)))
        await mesh.process(.received(ChannelID(50), LinkRig.helloRecord(bob)))
        #expect(radio.seeks == [true, false])
        #expect(await mesh.isSeeking == false)
    }

    @Test func bluetoothComingBackOnGivesAFreshSpell() {
        let rig = LinkRig(
            local: high, advertisesServiceData: false, background: true, configuration: LinkManager.Configuration(seekWakeBudget: 1))
        _ = rig.handle(.sighted(LinkRig.sighting(low, rssi: -95)))
        #expect(rig.radio.seeks == [true, false], "its one wake spent")
        _ = rig.handle(.state(.off))
        #expect(rig.radio.seeks == [true, false])
        _ = rig.handle(.state(.on))
        #expect(rig.radio.seeks == [true, false, true])
    }
}
