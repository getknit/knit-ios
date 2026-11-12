import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// A blinding iPhone with the phones it meets (ADR 2026-11.prsp, "Who dials"): another blinding iPhone, both ways and across
/// a slot edge with `TAG_NEXT` taken and no redial; a blinding Android; a clear Android, which the iPhone dials. And what the
/// radio hears of each HELLO for the GATT payload's rule 2, what becomes the link's form, and that no line names a tag.
@Suite struct BlindWriterPairTests {
    /// Keys whose tags, for `high` and `middle` in the rigs' first slot, sort one way (`highAbove`) or the other.
    static func keys(highAbove: Bool) -> (high: FakeKeys, middle: FakeKeys) {
        // The wall clock every rig starts at.
        let slot = BlindTag.slotOf(wallMilliseconds: 1_756_200_000_000)
        for byte in UInt8(1)...UInt8.max {
            let high = FakeKeys.key(1, byte: byte)
            let middle = FakeKeys.key(1, byte: byte &+ 1)
            let highTag = BlindFixture.tag(high.key, owner: LinkRig.high, slot: slot)
            let middleTag = BlindFixture.tag(middle.key, owner: LinkRig.middle, slot: slot)
            if (highTag > middleTag) == highAbove {
                return (FakeKeys(high), FakeKeys(middle))
            }
        }
        fatalError("no keys sort that way")
    }

    /// Each of two rigs hears the other's GATT payload every two seconds for `milliseconds`, both clocks moving together.
    static func hearEachOther(_ one: LinkRig, _ two: LinkRig, for milliseconds: Int64) {
        var left = milliseconds
        while left >= 0 {
            if let heard = two.sightingOfItsPayload(at: "addr-two") {
                _ = one.handle(.sighted(heard))
            }
            if let heard = one.sightingOfItsPayload(at: "addr-one") {
                _ = two.handle(.sighted(heard))
            }
            _ = one.advance(2000)
            _ = two.advance(2000)
            left -= 2000
        }
    }

    @Test(arguments: [true, false])
    func twoBlindingIPhonesLinkByTheLargerTagAndCrossASlotEdgeWithNoRedial(highAbove: Bool) throws {
        let keys = Self.keys(highAbove: highAbove)
        let logs = (RecordingLog(), RecordingLog())
        let high = LinkRig.blindingIPhone(LinkRig.high, keys: keys.high, log: logs.0)
        let middle = LinkRig.blindingIPhone(LinkRig.middle, keys: keys.middle, log: logs.1)
        var tags = Set([high.airedTag, middle.airedTag].compactMap(\.self))
        Self.hearEachOther(high, middle, for: 12_000)
        let (dialer, responder) = highAbove ? (high, middle) : (middle, high)
        #expect(responder.radio.dials.isEmpty, "the smaller tag waits for its head start")
        let dial = try #require(dialer.radio.dials.last)
        #expect(dial.address == RadioAddress(highAbove ? "addr-two" : "addr-one"))
        let pipe = RigPipe.dial(dialer, dial.channel, to: responder, on: ChannelID(90))
        #expect(dialer.links.neighbors.map(\.nodeId) == [responder.links.localId])
        #expect(responder.links.neighbors.map(\.nodeId) == [dialer.links.localId])
        #expect(dialer.links.linksProven == 1)
        // Past the head start, linked: the responder dials nothing, its peer's tag held off by the hint its HELLO left.
        Self.hearEachOther(high, middle, for: 30_000)
        #expect(responder.radio.dials.isEmpty)

        // The lead: each announces its coming tag over the link, and the other takes it.
        let edge = high.edge
        pipe.advance(edge - AdvertRotation.leadMilliseconds - high.wall)
        #expect(high.links.writerCounters.tagNextAnnounced == 1)
        #expect(middle.links.writerCounters.tagNextAnnounced == 1)
        #expect(high.links.aliasCounters.tagNextTaken == 1)
        #expect(middle.links.aliasCounters.tagNextTaken == 1)
        pipe.advance(edge - high.wall)
        #expect(high.links.writerCounters.rotationsBySlot == 1)
        #expect(middle.links.writerCounters.rotationsBySlot == 1)
        tags.formUnion([high.airedTag, middle.airedTag].compactMap(\.self))
        #expect(tags.count == 4)
        // Each hears the other's new tag: the announcement made it the link's claim, so nobody dials.
        let dials = (high.radio.dials.count, middle.radio.dials.count)
        Self.hearEachOther(high, middle, for: 40_000)
        #expect((high.radio.dials.count, middle.radio.dials.count) == dials)
        #expect(high.links.neighbors.count == 1)
        #expect(middle.links.neighbors.count == 1)
        #expect(high.links.aliasCounters.resolvedByClaim > 0)
        #expect(!namesATag(logs.0, tags))
        #expect(!namesATag(logs.1, tags))
    }

    @Test func aRandomTagReachesALinkedReaderWhichDoesNotDialIt() throws {
        // A mark that will not write airs a random tag at the edge, unannounced; with a key held it goes to the link
        // (`BluetoothMeshTransport.kt:1626`), and the reader attributes it to its link rather than dial it.
        let keys = Self.keys(highAbove: true)
        let high = LinkRig.blindingIPhone(LinkRig.high, keys: keys.high)
        let middle = LinkRig.blindingIPhone(LinkRig.middle, keys: keys.middle)
        Self.hearEachOther(high, middle, for: 12_000)
        let dial = try #require(high.radio.dials.last)
        let pipe = RigPipe.dial(high, dial.channel, to: middle, on: ChannelID(95))
        #expect(middle.links.neighbors.map(\.nodeId) == [LinkRig.high])
        keys.high.marks.answer = .refused
        pipe.advance(high.edge - high.wall)
        #expect(high.links.writerCounters.randomMarkFailed == 1)
        #expect(high.links.writerCounters.tagNextCurrent == 1)
        let random = try #require(high.airedTag)
        // Both blind and seal, so the link is sealed: the TAG_NEXT crosses inside a frame, read with the pipe's own keys.
        #expect(pipe.records(from: high).filter { $0.tag == .tagNext }.compactMap { NodeId(bytes: $0.payload) }.last == random)
        #expect(high.links.linksSealed == 1 && middle.links.linksSealed == 1)
        let dials = middle.radio.dials.count
        Self.hearEachOther(high, middle, for: 40_000)
        #expect(middle.radio.dials.count == dials, "no dial to our random tag")
        #expect(middle.links.neighbors.map(\.nodeId) == [LinkRig.high])
    }

    @Test func aBlindingIPhoneTagDialsABlindingAndroidWhoseTagSortsBelowIts() throws {
        let keys = FakeKeys()
        let rig = LinkRig.blindingIPhone(LinkRig.high, keys: keys)
        let mine = try #require(rig.airedTag)
        // A blinding Android whose tag sorts below ours: we dial.
        var android = BlindingPeer(LinkRig.low)
        var theirs = android.tag(wall: rig.wall)
        for byte in UInt8(1)...UInt8.max where theirs >= mine {
            android = BlindingPeer(LinkRig.low, keyByte: byte)
            theirs = android.tag(wall: rig.wall)
        }
        _ = rig.hear(android.sighting(theirs), for: 12_000)
        let dial = try #require(rig.radio.dials.last)
        _ = rig.handle(.connected(dial.channel))
        let ours = Hello(payload: try #require(rig.ourHelloPayload(on: dial.channel)))
        #expect(ours.told == mine.bytes)
        #expect(ours.addressed == theirs.bytes)
        let events = try android.answer(rig, on: dial.channel, told: theirs)
        #expect(events.contains { if case .up = $0 { true } else { false } })
        #expect(rig.links.blindWriter.linkForms[dial.channel] == BlindFixture.blinded(theirs), "the form we dialed")
        // The radio hears the reply only once its proof verified, with its `t`.
        #expect(rig.radio.hellos.last == FakeRadio.HeardHello(node: LinkRig.low, channel: dial.channel, told: theirs))
    }

    @Test func aBlindingAndroidWhoseTagSortsAboveOursDialsUsAndIsAdmitted() throws {
        let keys = FakeKeys()
        let rig = LinkRig.blindingIPhone(LinkRig.high, keys: keys)
        let mine = try #require(rig.airedTag)
        var android = BlindingPeer(LinkRig.low)
        var theirs = android.tag(wall: rig.wall)
        for byte in UInt8(1)...UInt8.max where theirs <= mine {
            android = BlindingPeer(LinkRig.low, keyByte: byte)
            theirs = android.tag(wall: rig.wall)
        }
        _ = rig.hear(android.sighting(theirs), for: 6000)
        let channel = ChannelID(91)
        _ = rig.handle(.accepted(channel))
        let hello = android.hello(told: theirs, addressed: mine)
        _ = rig.handle(.received(channel, required(LinkRecord(.hello, payload: hello).encoded)))
        let reply = rig.radio.records(on: channel).first.map { Hello(payload: $0.payload) }
        #expect(reply?.told == mine.bytes, "our reply tells our tag")
        _ = try rig.proveDialer(LinkRig.low, on: channel, hello: hello)
        #expect(rig.links.neighbors.map(\.nodeId) == [LinkRig.low])
        #expect(rig.links.blindWriter.linkForms[channel] == BlindFixture.blinded(theirs), "its honoured `t`")
        #expect(rig.radio.hellos.last == FakeRadio.HeardHello(node: LinkRig.low, channel: channel, told: theirs))
    }

    @Test func aBlindingIPhoneDialsAClearAndroidWhateverTheOrder() throws {
        let keys = FakeKeys()
        let rig = LinkRig.blindingIPhone(LinkRig.low, keys: keys)
        // Android's id sorts above ours, and it reads GATT payloads: a clear iPhone would wait to be dialed.
        rig.sightToPromotion(LinkRig.high)
        let dial = try #require(rig.radio.dials.last)
        _ = rig.handle(.connected(dial.channel))
        #expect(Hello(payload: try #require(rig.ourHelloPayload(on: dial.channel))).told == rig.airedTag?.bytes)
        _ = try rig.answerProving(LinkRig.high, on: dial.channel)
        #expect(rig.links.neighbors.map(\.nodeId) == [LinkRig.high])
        #expect(rig.links.blindWriter.linkForms[dial.channel] == .clear(LinkRig.high))
    }

    @Test func anAnnouncedFormBecomesTheLinksAtItsEdgeAndAResendAtOnce() throws {
        let keys = FakeKeys()
        let rig = LinkRig.blindingIPhone(LinkRig.high, keys: keys)
        let android = BlindingPeer(LinkRig.low)
        let channel = ChannelID(92)
        let now = android.tag(wall: rig.wall)
        _ = try android.dial(rig, on: channel, told: now)
        #expect(rig.links.blindWriter.linkForms[channel] == BlindFixture.blinded(now))
        // Its announcement, inside the window before the edge: held until the edge.
        rig.run(untilWall: rig.edge - 60_000)
        let next = android.tag(wall: rig.edge)
        _ = rig.handle(.received(channel, BlindingPeer.tagNext(next)))
        #expect(rig.links.blindWriter.linkForms[channel] == BlindFixture.blinded(now))
        // A later HELLO from that node names the announced tag to the radio, beside its `t`.
        let other = ChannelID(93)
        _ = rig.handle(.accepted(other))
        _ = rig.handle(.received(other, required(LinkRecord(.hello, payload: android.hello(told: now, addressed: nil)).encoded)))
        #expect(rig.radio.hellos.last == FakeRadio.HeardHello(node: LinkRig.low, channel: other, told: now, announced: next))
        rig.run(untilWall: rig.edge)
        #expect(rig.links.blindWriter.linkForms[channel] == BlindFixture.blinded(next))
        #expect(rig.links.writerCounters.linkFormsApplied == 1)
        // Mid-slot, a resend names the form on the air now: it applies at once.
        rig.run(untilWall: rig.wall + 5 * 60_000)
        let resent = android.tag(wall: rig.wall, restart: 1)
        _ = rig.handle(.received(channel, BlindingPeer.tagNext(resent)))
        #expect(rig.links.blindWriter.linkForms[channel] == BlindFixture.blinded(resent))
        _ = rig.handle(.closed(channel))
        #expect(rig.links.blindWriter.linkForms[channel] == nil)
    }

    @Test func anAnnouncementThatStopsStandingBeforeItsEdgeNeverApplies() throws {
        let keys = FakeKeys()
        let rig = LinkRig.blindingIPhone(LinkRig.high, keys: keys)
        let android = BlindingPeer(LinkRig.low)
        let channel = ChannelID(94)
        let now = android.tag(wall: rig.wall)
        _ = try android.dial(rig, on: channel, told: now)
        rig.run(untilWall: rig.edge - 60_000)
        // It announces a tag that a contact's key then names as that contact's own: once heard, the key's answer drops it.
        let forged = BlindFixture.tag(android.key, owner: LinkRig.middle, slot: BlindTag.slotOf(wallMilliseconds: rig.edge))
        _ = rig.handle(.received(channel, BlindingPeer.tagNext(forged)))
        rig.links.listPresenceKeys([LinkRig.middle: [android.key]])
        _ = rig.handle(.sighted(android.sighting(forged)))
        rig.run(untilWall: rig.edge)
        #expect(rig.links.blindWriter.linkForms[channel] == BlindFixture.blinded(now))
        #expect(rig.links.writerCounters.linkFormsApplied == 0)
    }
}
