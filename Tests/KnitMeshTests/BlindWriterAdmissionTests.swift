import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The two blinding admission rows wired into the responder (ADR 2026-11.prsp, "Admission"): `RefuseLegacy` first, with no
/// reply, against a dialer whose HELLO lacks `CAP_BLIND_ADVERT`; `RefuseHeld` against a dialer we hold a proven link to, our
/// tag resent over that link, unless it is quiet, a doorbell link, or the dialer may not hear our tag.
@Suite struct BlindWriterAdmissionTests {
    let keys = FakeKeys()
    let peer = BlindingPeer(LinkRig.low)

    /// `peer` dials `rig` on `channel` telling `told` and addressing `addressed`, offering its proof.
    func dial(_ rig: LinkRig, on channel: ChannelID, told: NodeId?, addressed: NodeId?) -> [LinkManager.Event] {
        _ = rig.handle(.accepted(channel))
        return rig.handle(.received(channel, required(LinkRecord(.hello, payload: peer.hello(told: told, addressed: addressed)).encoded)))
    }

    @Test func whileBlindingADialerThatReadsNoTagsIsRefusedFirstWithNoReply() throws {
        let rig = LinkRig.blindingIPhone(keys: keys)
        let tag = try #require(rig.airedTag)
        // An iPhone build from before the reader: it withholds the bit (``LinkManager/Configuration/withholdsBlindAdvert``).
        let legacy = LinkRig.iPhone(LinkRig.low, withholdsBlindAdvert: true)
        let hello = legacy.links.ourHello(addressing: BlindFixture.blinded(tag))
        #expect(!hello.capabilities.contains(.blindAdvert))
        let channel = ChannelID(60)
        _ = rig.handle(.accepted(channel))
        _ = rig.handle(.received(channel, required(LinkRecord(.hello, payload: hello.payload).encoded)))
        #expect(rig.radio.writes(on: channel).isEmpty, "no reply, no HELLO written")
        #expect(rig.radio.closed.contains(channel))
        #expect(rig.links.writerCounters.refusedLegacy == 1)
        #expect(rig.said("link refused \(LinkRig.low): it reads no tags"))
        #expect(rig.links.neighbors.isEmpty)
        // A clear iPhone admits the same dialer: the row is a blinding phone's alone.
        let reader = LinkRig.iPhone(LinkRig.high)
        _ = reader.handle(.accepted(channel))
        _ = reader.handle(.received(channel, required(LinkRecord(.hello, payload: hello.payload).encoded)))
        #expect(!reader.radio.writes(on: channel).isEmpty)
        #expect(reader.links.writerCounters.refusedLegacy == 0)
    }

    @Test func aDialerThatMissedOurRotationIsRefusedAndHearsOurTagOverItsHeldLink() throws {
        let rig = LinkRig.blindingIPhone(keys: keys)
        let held = ChannelID(61)
        _ = try peer.dial(rig, on: held, told: peer.tag(wall: rig.wall))
        // A key change rotates us at once and tells the peer; a second, inside the receiver's limit, is not told.
        for (generation, byte) in [(Int64(2), UInt8(0x22)), (3, 0x33)] {
            let key = FakeKeys.key(generation, byte: byte)
            keys.key = key
            rig.links.ownPresenceKeyChanged(key)
            _ = rig.advance(1000)
        }
        let current = try #require(rig.airedTag)
        #expect(rig.tagNexts(on: held).count == 1)
        #expect(rig.links.writerCounters.tagNextThrottled == 1)
        // The peer dials the tag it now hears: refused with no reply, its held link kept, and our tag resent there (still
        // inside the limit, so throttled).
        let channel = ChannelID(62)
        _ = dial(rig, on: channel, told: peer.tag(wall: rig.wall), addressed: current)
        #expect(rig.radio.writes(on: channel).isEmpty)
        #expect(rig.radio.closed.contains(channel))
        #expect(rig.links.neighbors.map(\.nodeId) == [LinkRig.low])
        #expect(rig.links.writerCounters.refusedHeld == 1)
        #expect(rig.links.writerCounters.tagNextThrottled == 2)
        #expect(rig.said("link refused \(LinkRig.low): it holds a link here, so it hears our tag there"))
        // Past the limit, its next dial heals it: refused, and told.
        let later = ChannelID(63)
        _ = rig.advance(TagNextSends<ChannelID>.minIntervalMilliseconds)
        _ = rig.handle(.received(held, [])) // the held link still answers
        _ = dial(rig, on: later, told: peer.tag(wall: rig.wall), addressed: current)
        #expect(rig.radio.writes(on: later).isEmpty)
        #expect(rig.tagNexts(on: held).last == current)
        #expect(rig.links.writerCounters.tagNextResent == 1)
        #expect(rig.links.writerCounters.refusedHeld == 2)
    }

    @Test func aQuietHeldLinkTakesNoRefusalAndTheDialerReplacesItOnceItProves() throws {
        let rig = LinkRig.blindingIPhone(keys: keys)
        let held = ChannelID(64)
        _ = try peer.dial(rig, on: held, told: peer.tag(wall: rig.wall))
        let tag = try #require(rig.airedTag)
        rig.run(until: rig.clock.monotonicMilliseconds() + LinkManager.heldQuietMilliseconds)
        let channel = ChannelID(65)
        let hello = peer.hello(told: peer.tag(wall: rig.wall), addressed: tag)
        _ = rig.handle(.accepted(channel))
        _ = rig.handle(.received(channel, required(LinkRecord(.hello, payload: hello).encoded)))
        #expect(rig.links.writerCounters.refusedHeld == 0)
        #expect(!rig.radio.writes(on: channel).isEmpty, "answered: the replace waits for its proof")
        let events = try rig.proveDialer(LinkRig.low, on: channel, hello: hello)
        #expect(events.contains(.down(LinkRig.low)))
        #expect(rig.links.neighbors.count == 1)
        #expect(rig.radio.closed.contains(held))
    }

    @Test func comingBackToTheFrontStartsEveryLinksQuietAgain() throws {
        let rig = LinkRig.blindingIPhone(keys: keys, background: true)
        let held = ChannelID(66)
        _ = try peer.dial(rig, on: held, told: peer.tag(wall: rig.wall))
        let tag = try #require(rig.airedTag)
        _ = rig.advance(LinkManager.heldQuietMilliseconds)
        // iOS held Knit suspended: that time read nothing, and is not counted.
        _ = rig.links.setInBackground(false)
        _ = dial(rig, on: ChannelID(67), told: peer.tag(wall: rig.wall), addressed: tag)
        #expect(rig.links.writerCounters.refusedHeld == 1)
        // So does a ring.
        _ = rig.advance(LinkManager.heldQuietMilliseconds)
        _ = rig.handle(.rung)
        _ = dial(rig, on: ChannelID(68), told: peer.tag(wall: rig.wall), addressed: tag)
        #expect(rig.links.writerCounters.refusedHeld == 2)
    }

    @Test func aDialerThatMayNotHearOurTagIsRefusedAllTheSameAndSentNothing() throws {
        // xp6d, step 5b's B2: an excluded peer's re-dials take the row with no resend, until its held link ends. Let
        // through, an unsighted one would replace a held link 30 s old at each rotation.
        let rig = LinkRig.blindingIPhone(keys: keys)
        let held = ChannelID(69)
        _ = try peer.dial(rig, on: held, told: peer.tag(wall: rig.wall))
        let tag = try #require(rig.airedTag)
        keys.deaf = [LinkRig.low]
        _ = rig.advance(LinkManager.Configuration().replaceMinHoldMilliseconds)
        _ = rig.handle(.received(held, []))
        let channel = ChannelID(70)
        _ = dial(rig, on: channel, told: peer.tag(wall: rig.wall), addressed: tag)
        #expect(rig.links.writerCounters.refusedHeld == 1)
        #expect(rig.radio.writes(on: channel).isEmpty, "no reply")
        #expect(rig.links.neighbors.map(\.nodeId) == [LinkRig.low], "the held link stands")
        #expect(rig.links.writerCounters.tagNextIneligible == 1)
        #expect(rig.tagNexts(on: held).isEmpty, "and nothing is sent to it")
    }

    @Test func aDialersHelloThatBeatsTheOverdueTimerStillFindsTheHeldLinkAnswering() throws {
        // On resume a radio event and the timer reach the link manager in no fixed order: the HELLO comes first here.
        let rig = LinkRig.blindingIPhone(keys: keys)
        let held = ChannelID(78)
        _ = try peer.dial(rig, on: held, told: peer.tag(wall: rig.wall))
        let tag = try #require(rig.airedTag)
        rig.clock.advance(3 * LinkManager.heldQuietMilliseconds / 2)
        let channel = ChannelID(79)
        _ = dial(rig, on: channel, told: peer.tag(wall: rig.wall), addressed: tag)
        #expect(rig.links.writerCounters.refusedHeld == 1, "no replace of a healthy held link")
        #expect(rig.radio.writes(on: channel).isEmpty)
        #expect(rig.links.neighbors.map(\.nodeId) == [LinkRig.low])
    }

    @Test func aWakeThatFindsTheWriteCheckLateStartsEveryLinksQuietAgain() throws {
        // A wake by a disconnect, not the front or a ring: the write-stall check fires late, its own sign of a suspension.
        let rig = LinkRig.blindingIPhone(keys: keys)
        let held = ChannelID(76)
        _ = try peer.dial(rig, on: held, told: peer.tag(wall: rig.wall))
        let tag = try #require(rig.airedTag)
        rig.clock.advance(3 * LinkManager.heldQuietMilliseconds / 2)
        _ = rig.links.advance()
        _ = dial(rig, on: ChannelID(77), told: peer.tag(wall: rig.wall), addressed: tag)
        #expect(rig.links.writerCounters.refusedHeld == 1, "the held link is not read as quiet")
    }

    @Test func aHeldDoorbellLinkNeverTakesTheRow() throws {
        let rig = LinkRig.blindingIPhone(keys: keys)
        let tag = try #require(rig.airedTag)
        // Another iPhone, its HELLO carrying the doorbell, linked and proven.
        let iphone = LinkRig.iPhone(LinkRig.low)
        let held = ChannelID(71)
        _ = rig.handle(.accepted(held))
        let hello = iphone.links.ourHello(addressing: BlindFixture.blinded(tag)).payload
        #expect(Hello(payload: hello).capabilities.contains(.doorbell))
        _ = rig.handle(.received(held, required(LinkRecord(.hello, payload: hello).encoded)))
        _ = try rig.proveDialer(LinkRig.low, on: held, hello: hello)
        #expect(rig.links.neighbors.count == 1)
        let again = iphone.links.ourHello(addressing: BlindFixture.blinded(tag)).payload
        let channel = ChannelID(72)
        _ = rig.handle(.accepted(channel))
        _ = rig.handle(.received(channel, required(LinkRecord(.hello, payload: again).encoded)))
        #expect(rig.links.writerCounters.refusedHeld == 0)
    }

    @Test func aClearIPhoneHasNoBlindingRowsEvenWhenItsTagIsDialedAfterAFlip() throws {
        let rig = LinkRig.blindingIPhone(keys: keys)
        let held = ChannelID(73)
        _ = try peer.dial(rig, on: held, told: peer.tag(wall: rig.wall))
        let tag = try #require(rig.airedTag)
        rig.links.setBlinding(false)
        // The flip closed the held link, and the peer relinks to our id.
        #expect(rig.radio.closed.contains(held))
        #expect(rig.links.advance() == [.down(peer.id)])
        _ = try peer.dial(rig, on: ChannelID(80), told: peer.tag(wall: rig.wall))
        // Our previous form is still a tag a dial may name: the row stands, with nothing to resend.
        _ = dial(rig, on: ChannelID(74), told: peer.tag(wall: rig.wall), addressed: tag)
        #expect(rig.links.writerCounters.refusedHeld == 1)
        #expect(rig.links.writerCounters.tagNextResent == 0)
        // A dialer that reads no tags is no legacy refusal while we air our id.
        let legacy = LinkRig.iPhone(LinkRig.middle, withholdsBlindAdvert: true)
        let channel = ChannelID(75)
        _ = rig.handle(.accepted(channel))
        _ = rig.handle(
            .received(
                channel, required(LinkRecord(.hello, payload: legacy.links.ourHello(addressing: .clear(LinkRig.high)).payload).encoded)))
        #expect(rig.links.writerCounters.refusedLegacy == 0)
        #expect(!rig.radio.writes(on: channel).isEmpty)
    }
}
