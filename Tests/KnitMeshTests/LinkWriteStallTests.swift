import KnitWire
import Testing
@testable import KnitMesh

/// A live link whose writes stall is closed after 120 s of running time, unless its peer looks like an iPhone that
/// asked to be rung (ADR 2026-10.f5zs, Android's `WRITE_STALL_MS` in `LinkSilence.kt`). The radio's level is set by
/// hand on the fake, as a real radio's queue would read.
@Suite struct LinkWriteStallTests {
    private let low = LinkRig.low
    private let high = LinkRig.high
    private let channel = ChannelID(40)
    /// Bytes waiting that never move.
    private let stuck = OutboxLevel(queuedBytes: 50_000, writtenBytes: 1000)
    private static let doorbellHello: Capabilities = 0x1FFF

    /// A rig on `local` with `peer` linked on ``channel`` by its own dial, its HELLO carrying `capabilities`, and the
    /// channel reading `level` from the start.
    private func linked(
        local: NodeId? = nil, peer: NodeId? = nil, capabilities: Capabilities = 0xFFF, level: OutboxLevel
    ) -> (rig: LinkRig, linkedAt: Int64) {
        let rig = LinkRig(local: local ?? low)
        rig.radio.setLevel(level, on: channel)
        _ = rig.accept(peer ?? high, on: channel, capabilities: capabilities)
        return (rig, rig.clock.monotonicMilliseconds())
    }

    private func isLinked(_ rig: LinkRig, _ peer: NodeId) -> Bool {
        rig.links.neighbors.contains { $0.nodeId == peer }
    }

    // MARK: The close

    @Test func aLinkWhoseWritesStandStillIsClosedAfter120Seconds() {
        let (rig, linkedAt) = linked(level: stuck)
        #expect(rig.links.nextDeadline == linkedAt + 30_000, "a check every 30 s while a link is up")
        let early = rig.run(until: linkedAt + 119_999)
        #expect(early.isEmpty)
        #expect(isLinked(rig, high))
        let events = rig.run(until: linkedAt + 150_000)
        #expect(events.contains(.down(high)))
        #expect(rig.radio.closed == [channel])
        #expect(rig.log.all.contains("warning link ch40 write stalled for 120000 ms"))
        #expect(!rig.log.all.contains { $0.contains("timed out") }, "the harness reads that as a missed HELLO")
        #expect(rig.links.nextDeadline == nil, "no link, no check")
    }

    @Test func aSlowLinkWhoseBytesKeepMovingIsNeverClosed() {
        // The Pixel 3's back-fill drained over 393 s on 2026-09-27; bytes always waited, and some always moved.
        var level = OutboxLevel(queuedBytes: 200_000, writtenBytes: 0)
        let (rig, linkedAt) = linked(level: level)
        for step in 1...40 {
            level.writtenBytes += 100
            rig.radio.setLevel(level, on: channel)
            rig.run(until: linkedAt + Int64(step) * 10_000)
        }
        #expect(isLinked(rig, high), "400 s of slow writes")
        #expect(rig.radio.closed.isEmpty)
    }

    @Test func aLinkWithNothingQueuedIsNeverClosed() {
        let (rig, linkedAt) = linked(level: OutboxLevel(queuedBytes: 0, writtenBytes: 1000))
        rig.run(until: linkedAt + 400_000)
        #expect(isLinked(rig, high))
    }

    @Test func aLinkThatStallsAfterMovingIsClosed120SecondsAfterItsLastProgressWasSeen() {
        let (rig, linkedAt) = linked(level: stuck)
        rig.run(until: linkedAt + 45_000)
        rig.radio.setLevel(OutboxLevel(queuedBytes: 40_000, writtenBytes: 11_000), on: channel)
        // Seen moving at 60 s, then never again.
        rig.run(until: linkedAt + 179_999)
        #expect(isLinked(rig, high))
        rig.run(until: linkedAt + 180_000)
        #expect(!isLinked(rig, high))
    }

    @Test func theStallCloseBacksOffNobody() throws {
        // Android redials a link it closed as silent at once (`closeSilent`), and so may we.
        let rig = LinkRig(local: high)
        try #require(try rig.link(low) == ChannelID(1))
        rig.radio.setLevel(stuck, on: ChannelID(1))
        let linkedAt = rig.clock.monotonicMilliseconds()
        for second in stride(from: 2, through: 150, by: 2) {
            rig.run(until: linkedAt + Int64(second) * 1000)
            _ = rig.handle(.sighted(LinkRig.sighting(low)))
        }
        #expect(rig.radio.closed == [ChannelID(1)])
        #expect(rig.radio.dials.count == 2, "dialed again on the next sighting, with no backoff to wait out")
    }

    // MARK: Running time only

    @Test func aCheckThatFiresLateStartsTheCountAgain() {
        let (rig, linkedAt) = linked(level: stuck)
        rig.run(until: linkedAt + 90_000)
        // Suspended through the 120 s check, and woken 80 s after it.
        rig.clock.advance(110_000)
        let woken = rig.links.advance()
        #expect(woken.isEmpty)
        #expect(isLinked(rig, high))
        #expect(rig.log.all.contains("debug link write check ran 80000 ms late, so every link's stall count starts again"))
        rig.run(until: linkedAt + 200_000 + 119_999)
        #expect(isLinked(rig, high), "120 s of running time not yet spent")
        rig.run(until: linkedAt + 200_000 + 120_000)
        #expect(!isLinked(rig, high))
    }

    @Test func comingToTheFrontStartsTheCountAgainEveryTime() {
        let (rig, linkedAt) = linked(level: stuck)
        rig.run(until: linkedAt + 90_000)
        // The app was already at the front: the report still counts, since its timer and the front race on resume.
        _ = rig.links.setInBackground(false)
        rig.run(until: linkedAt + 180_000)
        #expect(isLinked(rig, high))
        _ = rig.links.setInBackground(true)
        _ = rig.links.setInBackground(false)
        rig.run(until: linkedAt + 180_000 + 119_999)
        #expect(isLinked(rig, high))
        rig.run(until: linkedAt + 180_000 + 120_000)
        #expect(!isLinked(rig, high))
    }

    @Test func aRingStartsTheCountAgain() {
        let (rig, linkedAt) = linked(level: stuck)
        rig.run(until: linkedAt + 90_000)
        _ = rig.handle(.rung)
        rig.run(until: linkedAt + 209_999)
        #expect(isLinked(rig, high))
        rig.run(until: linkedAt + 210_000)
        #expect(!isLinked(rig, high))
    }

    // MARK: Who is exempt

    @Test func aDoorbellLinkNeverHeardIsLeftAlone() {
        // An iPhone accepted unsighted, as Android never hears a backgrounded one, and iOS suspends Knit with it up.
        let (rig, linkedAt) = linked(capabilities: Self.doorbellHello, level: stuck)
        rig.run(until: linkedAt + 400_000)
        #expect(isLinked(rig, high))
    }

    @Test func aDoorbellLinkHeardOnlyThroughItsGattPayloadIsLeftAlone() {
        // A GATT payload carries no digest cue (ADR 2026-09.xzpt): the iPhone's own form.
        // Sighted and above us, so admitted as a dialer whose turn it is.
        let rig = LinkRig(local: low)
        _ = rig.handle(.sighted(Self.sighting(high, cue: 0)))
        rig.radio.setLevel(stuck, on: channel)
        _ = rig.accept(high, on: channel, capabilities: Self.doorbellHello)
        let linkedAt = rig.clock.monotonicMilliseconds()
        #expect(isLinked(rig, high))
        for second in stride(from: 10, through: 400, by: 10) {
            rig.run(until: linkedAt + Int64(second) * 1000)
            _ = rig.handle(.sighted(Self.sighting(high, cue: 0)))
        }
        #expect(isLinked(rig, high))
    }

    @Test func aDoorbellClaimFromAPeerHeardThroughServiceDataIsClosed() {
        // Android never sends the bit, so a claim from a node heard with service data is not an iPhone's.
        let rig = LinkRig(local: low)
        _ = rig.handle(.sighted(Self.sighting(high, cue: 7)))
        rig.radio.setLevel(stuck, on: channel)
        _ = rig.accept(high, on: channel, capabilities: Self.doorbellHello)
        let linkedAt = rig.clock.monotonicMilliseconds()
        #expect(isLinked(rig, high))
        rig.run(until: linkedAt + 150_000)
        #expect(!isLinked(rig, high))
        #expect(rig.log.all.contains("warning link ch40 write stalled for 120000 ms"))
    }

    @Test func aDoorbellLinkLosesItsExemptionOnceServiceDataIsHeardForItsPeer() {
        let (rig, linkedAt) = linked(capabilities: Self.doorbellHello, level: stuck)
        rig.run(until: linkedAt + 200_000)
        #expect(isLinked(rig, high), "exempt so far")
        _ = rig.handle(.sighted(Self.sighting(high, cue: 7)))
        rig.run(until: linkedAt + 200_000 + 150_000)
        #expect(!isLinked(rig, high), "judged from the check that found it no longer exempt")
    }

    @Test func onlyALiveLinkCanBeExempt() {
        // The watch holds only live links, so it never asks about another channel; asked anyway, the answer is to judge.
        let (rig, _) = linked(capabilities: Self.doorbellHello, level: stuck)
        #expect(rig.links.isExemptFromStallClose(channel))
        #expect(!rig.links.isExemptFromStallClose(ChannelID(41)), "no link on it, so no iPhone to leave alone")
        _ = rig.handle(.closed(channel))
        #expect(!rig.links.isExemptFromStallClose(channel), "its link is down")
    }

    private static func sighting(_ peer: NodeId, cue: UInt32) -> RadioSighting {
        let advert = AdvertPayload(capabilities: 0xFFF, nodeId: peer, digestCue: cue, psm: 0x80, flags: AdvertPayload.dialsGattPeersFlag)
        return RadioSighting(address: RadioAddress("addr-\(peer)"), advert: advert, rssi: -50)
    }

    // MARK: What the engine asks of the link

    @Test func queuedBytesFollowsTheLiveLinksLevel() {
        let (rig, _) = linked(level: OutboxLevel(queuedBytes: 300_000, writtenBytes: 9))
        #expect(rig.links.queuedBytes(to: high) == 300_000)
        rig.radio.setLevel(OutboxLevel(queuedBytes: 12, writtenBytes: 300_000), on: channel)
        #expect(rig.links.queuedBytes(to: high) == 12)
        #expect(rig.links.queuedBytes(to: LinkRig.middle) == 0, "unlinked")
        _ = rig.handle(.closed(channel))
        #expect(rig.links.queuedBytes(to: high) == 0, "its link is down")
    }

    @Test func hasCrossedFollowsBothWaysOnTheLiveLink() throws {
        let rig = LinkRig(local: low)
        _ = rig.accept(high, on: channel)
        let ours = LinkRig.signedFrame("ours", sig: 1)
        let theirs = LinkRig.signedFrame("theirs", sig: 2)
        let oursKey = try #require(FrameKey.ofSigned(ours))
        let theirsKey = try #require(FrameKey.ofSigned(theirs))
        #expect(!rig.links.hasCrossed(oursKey, to: high))
        rig.links.send(ours, to: high)
        _ = rig.handle(.received(channel, LinkRig.frameRecord(theirs)))
        #expect(rig.links.hasCrossed(oursKey, to: high), "what we wrote")
        #expect(rig.links.hasCrossed(theirsKey, to: high), "what it gave us")
        #expect(!rig.links.hasCrossed(oursKey, to: LinkRig.middle), "unlinked")
        rig.clock.advance(600_001)
        #expect(!rig.links.hasCrossed(oursKey, to: high), "past the 10 minute window")
        _ = rig.handle(.closed(channel))
        #expect(!rig.links.hasCrossed(theirsKey, to: high))
    }
}
