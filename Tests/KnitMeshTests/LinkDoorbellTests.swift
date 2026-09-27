import KnitMesh
import KnitWire
import Testing

/// When the link manager rings a peer's doorbell: iOS wakes a suspended iPhone for a write to it, and not for data on
/// the link, so every frame that goes out needs a ring soon after, and a burst of them needs few.
struct LinkDoorbellTests {
    private let interval: Int64 = 5000

    @Test func aFrameRingsTheLinkItWentOut() throws {
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        #expect(rig.radio.rings.isEmpty)
        rig.links.send(LinkRig.signedFrame("f1"), to: LinkRig.low)
        #expect(rig.radio.rings == [id])
        #expect(rig.links.rings == 1)
    }

    @Test func aBurstRingsAtItsStartAndOnceAfterItsEnd() throws {
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        rig.links.send(LinkRig.signedFrame("f1"), to: nil)
        rig.clock.advance(1000)
        rig.links.send(LinkRig.signedFrame("f2", sig: 2), to: nil)
        rig.clock.advance(1000)
        rig.links.send(LinkRig.signedFrame("f3", sig: 3), to: nil)
        #expect(rig.radio.rings == [id])
        #expect(rig.links.nextDeadline == rig.clock.monotonicMilliseconds() - 2000 + interval)
        _ = rig.advance(2999)
        #expect(rig.radio.rings == [id])
        _ = rig.advance(1)
        #expect(rig.radio.rings == [id, id])
        _ = rig.advance(60_000)
        #expect(rig.radio.rings == [id, id])
    }

    @Test func aFrameAfterTheIntervalRingsAtOnce() throws {
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        rig.links.send(LinkRig.signedFrame("f1"), to: nil)
        rig.clock.advance(interval)
        rig.links.send(LinkRig.signedFrame("f2", sig: 2), to: nil)
        #expect(rig.radio.rings == [id, id])
    }

    @Test func digestsDoNotRing() throws {
        let rig = LinkRig(local: LinkRig.high)
        _ = try rig.link(LinkRig.low)
        rig.links.sendDigest(["a", "b"], to: LinkRig.low)
        _ = rig.advance(interval)
        #expect(rig.radio.rings.isEmpty)
    }

    @Test func aFrameTheLinkAlreadyCarriedDoesNotRing() throws {
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        let frame = LinkRig.signedFrame("f1")
        _ = rig.handle(.received(id, LinkRig.frameRecord(frame)))
        rig.links.send(frame, to: nil)
        #expect(rig.radio.rings.isEmpty)
    }

    @Test func eachLinkRingsOnItsOwnSchedule() throws {
        let rig = LinkRig(local: LinkRig.high)
        let low = try rig.link(LinkRig.low)
        let middle = try rig.link(LinkRig.middle)
        rig.links.send(LinkRig.signedFrame("f1"), to: LinkRig.low)
        rig.clock.advance(1000)
        rig.links.send(LinkRig.signedFrame("f2", sig: 2), to: nil)
        #expect(rig.radio.rings == [low, middle])
        _ = rig.advance(interval - 1000)
        #expect(rig.radio.rings == [low, middle, low])
    }

    @Test func aLinkThatClosesForgetsItsNextRing() throws {
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        rig.links.send(LinkRig.signedFrame("f1"), to: nil)
        rig.links.send(LinkRig.signedFrame("f2", sig: 2), to: nil)
        _ = rig.handle(.closed(id))
        #expect(rig.links.nextDeadline == nil || rig.links.nextDeadline != rig.clock.monotonicMilliseconds() + interval)
        _ = rig.advance(interval)
        #expect(rig.radio.rings == [id])
    }

    @Test func ringsHeardAreCounted() {
        let rig = LinkRig(local: LinkRig.high)
        #expect(rig.handle(.rung).isEmpty)
        #expect(rig.handle(.rung).isEmpty)
        #expect(rig.links.ringsHeard == 2)
        #expect(rig.links.rings == 0)
    }

    @Test func aZeroIntervalNeverRings() throws {
        let rig = LinkRig(local: LinkRig.high, configuration: LinkManager.Configuration(ringIntervalMilliseconds: 0))
        _ = try rig.link(LinkRig.low)
        rig.links.send(LinkRig.signedFrame("f1"), to: nil)
        _ = rig.advance(interval)
        #expect(rig.radio.rings.isEmpty)
    }
}
