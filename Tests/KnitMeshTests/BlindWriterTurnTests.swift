import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The writer's slot turn and its sends on a ``LinkRig`` (ADR 2026-11.prsp, "Rotation" and "The link"; knit-next's
/// `RotationTurnTest` at `cad69c77b`, here deadlines the `Mesh` actor's timer wakes for): the announcement at the lead, the
/// announced tag at the edge, a late wake's unannounced rotation and its one send, a clock set back, a mark that will not
/// write, no key, the radio down, and the forced rotation's guards.
@Suite struct BlindWriterTurnTests {
    let keys = FakeKeys()

    @Test func theTurnAnnouncesAtTheLeadAndAirsTheAnnouncedTagAtTheEdge() throws {
        let rig = LinkRig.blindingIPhone(LinkRig.high, keys: keys)
        let peer = BlindingPeer(LinkRig.low)
        let channel = ChannelID(50)
        _ = try peer.dial(rig, on: channel, told: peer.tag(wall: rig.wall))
        let key = try #require(keys.key)
        let edge = rig.edge
        let slot = rig.slot
        rig.run(untilWall: edge - AdvertRotation.leadMilliseconds - 1)
        #expect(rig.tagNexts(on: channel).isEmpty, "nothing before the lead")
        rig.run(untilWall: edge - AdvertRotation.leadMilliseconds)
        let announced = rig.tag(key, slot: slot + 1)
        #expect(rig.tagNexts(on: channel) == [announced])
        #expect(rig.said("link tag next to \(LinkRig.low) on \(channel)"))
        #expect(rig.radio.rings.isEmpty, "a link record, never a ring")
        rig.run(untilWall: edge - 1)
        #expect(rig.airedTag == rig.tag(key, slot: slot))
        rig.run(untilWall: edge)
        #expect(rig.airedTag == announced, "the announced tag, exactly")
        #expect(rig.tagNexts(on: channel) == [announced], "no second send: it was told")
        let counted = rig.links.writerCounters
        #expect(counted.rotationsBySlot == 1)
        #expect(counted.tagNextAnnounced == 1)
        #expect(counted.unannounced == 1, "the bring-up's alone")
        #expect(rig.links.mine.previous == BlindFixture.blinded(rig.tag(key, slot: slot)))
    }

    @Test func aLinkThatComesUpWhileAnAnnouncementStandsIsToldItToo() throws {
        let rig = LinkRig.blindingIPhone(LinkRig.high, keys: keys)
        let key = try #require(keys.key)
        rig.run(untilWall: rig.edge - AdvertRotation.leadMilliseconds + 10_000)
        let peer = BlindingPeer(LinkRig.low)
        _ = try peer.dial(rig, on: ChannelID(51), told: peer.tag(wall: rig.wall))
        #expect(rig.tagNexts(on: ChannelID(51)) == [rig.tag(key, slot: rig.slot + 1)])
    }

    @Test func aLateWakeRotatesAtOnceUnannouncedAndSendsTheFormOnce() throws {
        let rig = LinkRig.blindingIPhone(LinkRig.high, keys: keys)
        let peer = BlindingPeer(LinkRig.low)
        let channel = ChannelID(52)
        _ = try peer.dial(rig, on: channel, told: peer.tag(wall: rig.wall))
        let key = try #require(keys.key)
        // Suspended through the lead and the edge: the first wake is 31 minutes past it, a whole slot before the next lead.
        let late = rig.edge + 31 * 60_000
        rig.clock.advance(late - rig.wall)
        _ = rig.links.advance()
        let now = try #require(rig.airedTag)
        #expect(now == rig.tag(key, slot: rig.slot))
        #expect(rig.tagNexts(on: channel) == [now], "the form just aired, once, never an announcement as well")
        #expect(rig.links.writerCounters.unannounced == 2)
        #expect(rig.links.writerCounters.tagNextCurrent == 1)
    }

    @Test func aClockSetBackBelowTheSlotRotatesAtOnceToARandomTagAndAsksForOnePass() throws {
        let rig = LinkRig.blindingIPhone(keys: keys)
        let first = try #require(rig.airedTag)
        rig.clock.setWall(rig.wall - 2 * 3_600_000)
        _ = rig.links.wallClockChanged()
        let now = try #require(rig.airedTag)
        #expect(now != first)
        #expect(AdvertForm.hasTagPrefix(now.bytes))
        let counted = rig.links.writerCounters
        #expect(counted.randomScheduled == 1)
        #expect(counted.stale == 1, "the mark is past the window's lead")
        #expect(keys.markPasses == [1])
        // Each later rotation under the generation finds it stale too, and asks nothing more.
        rig.links.setBlinding(false)
        rig.links.setBlinding(true)
        #expect(keys.markPasses == [1])
        #expect(rig.links.writerCounters.staleMarkPasses == 1)
    }

    @Test func aMarkThatWillNotWriteAirsARandomTagAnnouncedToNoneAndSentOnce() throws {
        let rig = LinkRig.blindingIPhone(LinkRig.high, keys: keys)
        let peer = BlindingPeer(LinkRig.low)
        let channel = ChannelID(53)
        _ = try peer.dial(rig, on: channel, told: peer.tag(wall: rig.wall))
        keys.marks.answer = .refused
        rig.run(untilWall: rig.edge)
        #expect(rig.links.writerCounters.randomMarkFailed == 1)
        #expect(rig.links.writerCounters.tagNextAnnounced == 0, "a reservation that would not write announces nothing")
        // With a key held the random tag goes once to the link, as Android sends it, so the peer attributes it to us.
        #expect(rig.links.writerCounters.tagNextCurrent == 1)
        #expect(rig.tagNexts(on: channel) == [rig.airedTag].compactMap(\.self))
    }

    @Test func noKeyAnnouncesNothingAndSendsNothing() throws {
        let rig = LinkRig.blindingIPhone(LinkRig.high, keys: FakeKeys(nil))
        let peer = BlindingPeer(LinkRig.low)
        let channel = ChannelID(54)
        _ = try peer.dial(rig, on: channel, told: peer.tag(wall: rig.wall))
        rig.run(untilWall: rig.edge)
        #expect(rig.tagNexts(on: channel).isEmpty, "a random tag is never sent")
        #expect(rig.links.writerCounters.tagNextNoKey == 1)
    }

    @Test func aRadioThatGoesOffStopsTheTurn() {
        let rig = LinkRig.blindingIPhone(keys: keys)
        _ = rig.handle(.state(.off))
        #expect(rig.links.nextDeadline == nil)
        rig.run(untilWall: rig.edge + BlindTag.slotMilliseconds)
        #expect(rig.links.writerCounters.rotationsBySlot == 0)
        #expect(rig.radio.advertised.count == 1)
    }

    @Test func aForcedRotationRunsOnlyWhenNothingStandsInItsWay() throws {
        let rig = LinkRig.blindingIPhone(LinkRig.high, keys: keys)
        let grace = LinkManager.forcedRotationGraceMilliseconds
        #expect(rig.links.forceRotation().refused == .grace, "the bring-up installed a moment ago")
        rig.clock.advance(grace)
        #expect(rig.links.forceRotation(radioSettling: true).refused == .grace, "the radio's payload add is in flight")
        let first = rig.links.forceRotation()
        #expect(first.rotated)
        #expect(first.epochAfter == first.epochBefore + 1)
        #expect(rig.links.writerCounters.rotationsForced == 1)
        let peer = BlindingPeer(LinkRig.low)
        _ = try peer.dial(rig, on: ChannelID(55), told: peer.tag(wall: rig.wall))
        rig.clock.advance(grace)
        #expect(rig.links.forceRotation().rotated, "a link told nothing yet")
        rig.clock.advance(grace)
        let throttled = rig.links.forceRotation()
        #expect(throttled.refused == .throttled, "its form went to a link within the receiver's limit")
        #expect(throttled.epochAfter == throttled.epochBefore, "nothing rotated")
        rig.run(untilWall: rig.edge - AdvertRotation.leadMilliseconds)
        #expect(rig.links.forceRotation().refused == .announced, "an announcement stands")
        rig.links.setBlinding(false)
        rig.clock.advance(grace)
        #expect(rig.links.forceRotation().refused == .clear, "nothing blinded on the air")
        _ = rig.handle(.state(.off))
        #expect(rig.links.forceRotation().refused == .radioDown)
        #expect(rig.links.writerCounters.rotationsForced == 2)
    }

    @Test func aStepDueNowIsADeadlineNow() {
        let rig = LinkRig.blindingIPhone(keys: keys)
        // The clock reaches the lead with no advance run: the timer is aimed at now.
        rig.clock.advance(rig.edge - AdvertRotation.leadMilliseconds - rig.wall)
        #expect(rig.links.nextDeadline == rig.clock.monotonicMilliseconds())
    }

    @Test func anAnnouncementWaitsBehindWhatTheLinkHoldsAndIsCounted() throws {
        let rig = LinkRig.blindingIPhone(LinkRig.high, keys: keys)
        let peer = BlindingPeer(LinkRig.low)
        let channel = ChannelID(56)
        _ = try peer.dial(rig, on: channel, told: peer.tag(wall: rig.wall))
        rig.run(untilWall: rig.edge - AdvertRotation.leadMilliseconds - 1)
        rig.radio.setLevel(OutboxLevel(queuedBytes: 20_000, writtenBytes: 0), on: channel)
        rig.run(untilWall: rig.edge - AdvertRotation.leadMilliseconds)
        #expect(rig.tagNexts(on: channel).count == 1, "first in, first out, as Android queues it")
        #expect(rig.links.writerCounters.tagNextBehindQueue == 1)
    }

    @Test func noTagNextGoesToABlockedOrDepartedPeer() throws {
        let rig = LinkRig.blindingIPhone(LinkRig.high, keys: keys)
        let peer = BlindingPeer(LinkRig.low)
        let channel = ChannelID(57)
        _ = try peer.dial(rig, on: channel, told: peer.tag(wall: rig.wall))
        keys.deaf = [LinkRig.low]
        rig.run(untilWall: rig.edge)
        #expect(rig.tagNexts(on: channel).isEmpty)
        #expect(rig.links.writerCounters.tagNextIneligible == 1, "the announcement; the edge's rotation was announced")
        #expect(rig.links.writerCounters.rotationsBySlot == 1)
    }

    @Test func aResendWaitsWhileAnAnnouncementStands() throws {
        let rig = LinkRig.blindingIPhone(LinkRig.high, keys: keys)
        let peer = BlindingPeer(LinkRig.low)
        let held = ChannelID(58)
        _ = try peer.dial(rig, on: held, told: peer.tag(wall: rig.wall))
        let tag = try #require(rig.airedTag)
        rig.run(untilWall: rig.edge - AdvertRotation.leadMilliseconds)
        #expect(rig.tagNexts(on: held).count == 1)
        // The peer, its link answering, dials the tag on the air while the announcement stands: refused, and nothing but the
        // announcement goes.
        _ = rig.handle(.received(held, []))
        let channel = ChannelID(59)
        _ = rig.handle(.accepted(channel))
        let hello = peer.hello(told: peer.tag(wall: rig.wall), addressed: tag)
        _ = rig.handle(.received(channel, required(LinkRecord(.hello, payload: hello).encoded)))
        #expect(rig.links.writerCounters.refusedHeld == 1)
        #expect(rig.links.writerCounters.tagNextBeforeAnnounce == 1)
        #expect(rig.tagNexts(on: held).count == 1)
    }
}
