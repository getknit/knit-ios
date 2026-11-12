import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// What the relink window never overrides (``LinkManager/relinksOutOfOrder(_:on:now:)``): an attempt of ours to link the
/// peer, of any kind, keeps "we dial it", so two crossing dials cannot both be admitted and leave each end's keep-older to
/// retire both links (ADR 2026-11.sv5t); and the rows ahead of it, `RefuseLegacy` and `RefuseHeld`, still come first.
@Suite struct LinkRelinkGuardTests {
    private let low = LinkRig.low
    private let high = LinkRig.high

    /// `low` dials `rig` unsighted on `id`, proves itself, and the radio then closes the link: the window opens.
    private func closedByTheRadio(_ rig: LinkRig, on id: ChannelID = ChannelID(100)) throws {
        let (hello, _) = rig.acceptProving(low, on: id)
        _ = try rig.proveDialer(low, on: id, hello: hello)
        _ = rig.handle(.closed(id))
        #expect(rig.relinkOpen(for: low))
    }

    @Test func ourOwnClearDialOpenToItKeepsWeDialIt() throws {
        let rig = LinkRig(local: high)
        try closedByTheRadio(rig)
        let closed = rig.clock.monotonicMilliseconds()
        rig.sightToPromotion(low)
        rig.advance(4000, hearing: low)
        let dial = try #require(rig.radio.dials.last, "our backoff ran out and the dwell ended")
        #expect(rig.clock.monotonicMilliseconds() - closed < 30_000)
        _ = rig.acceptProving(low, on: ChannelID(101))
        #expect(rig.radio.closed.contains(ChannelID(101)))
        #expect(rig.said("link refused \(low): we dial it"))
        #expect(!rig.said("link \(low) relinks out of order on ch101"))
        #expect(!rig.radio.closed.contains(dial.channel), "our dial goes on")
    }

    /// A blinding peer whose tag a key resolves: our head start toward it is a tag dial, attributed to its id. A dialer that
    /// tells no tag is judged clear, and so out of order.
    @Test func ourOwnHeadStartTagDialOpenToItKeepsWeDialIt() throws {
        let rig = LinkRig.iPhone()
        let peer = BlindingPeer(low)
        rig.links.listPresenceKeys([low: [peer.key]])
        let tag = peer.tag(wall: rig.wall)
        rig.hear(peer.sighting(tag), for: 24_000)
        let first = try #require(rig.radio.dials.last)
        _ = rig.handle(.connected(first.channel))
        _ = try peer.answer(rig, on: first.channel, told: tag)
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
        _ = rig.handle(.closed(first.channel))
        #expect(rig.relinkOpen(for: low))
        let closed = rig.clock.monotonicMilliseconds()
        for _ in 0..<12 where rig.radio.dials.count == 1 {
            rig.hear(peer.sighting(tag), for: 2000)
        }
        let dial = try #require(rig.radio.dials.last)
        #expect(dial.channel != first.channel)
        #expect(rig.clock.monotonicMilliseconds() - closed < 30_000)
        #expect(rig.log.all.contains { $0.hasPrefix("info link head start over for \(low) (dwell=") })
        let hello = peer.hello(told: nil, addressed: high)
        _ = rig.handle(.accepted(ChannelID(101)))
        _ = rig.handle(.received(ChannelID(101), required(LinkRecord(.hello, payload: hello).encoded)))
        #expect(rig.radio.closed.contains(ChannelID(101)))
        #expect(rig.said("link refused \(low): we dial it"))
        #expect(!rig.said("link \(low) relinks out of order on ch101"))
    }

    /// Our relink dial, sent on the first sighting past the close's backoff (``LinkManager/withRelinkDwell(_:now:)``), is an
    /// attempt of ours like any other: the peer's crossing redial is refused as one we dial.
    @Test func ourRelinkDialOpenToItKeepsWeDialIt() throws {
        let rig = LinkRig(local: high)
        try closedByTheRadio(rig)
        let closed = rig.clock.monotonicMilliseconds()
        rig.run(until: closed + 15_000)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        let dial = try #require(rig.radio.dials.last, "dialed on the sighting, with no dwell")
        _ = rig.acceptProving(low, on: ChannelID(101))
        #expect(rig.radio.closed.contains(ChannelID(101)))
        #expect(rig.said("link refused \(low): we dial it"))
        #expect(!rig.said("link \(low) relinks out of order on ch101"))
        #expect(!rig.radio.closed.contains(dial.channel), "our dial goes on")
        #expect(rig.relinkOpen(for: low), "a refusal consumes nothing")
    }

    /// Our relink dial failed before its channel opened: nothing of ours is open, so the peer's redial is admitted through
    /// the window.
    @Test func ourRelinkDialFailingLeavesTheWindowForThePeersRedial() throws {
        let rig = LinkRig(local: high)
        try closedByTheRadio(rig)
        let closed = rig.clock.monotonicMilliseconds()
        rig.run(until: closed + 15_000)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        let dial = try #require(rig.radio.dials.last)
        _ = rig.handle(.dialFailed(dial.channel))
        _ = rig.acceptProving(low, on: ChannelID(101))
        #expect(!rig.radio.closed.contains(ChannelID(101)))
        #expect(rig.said("link \(low) relinks out of order on ch101"))
    }

    /// The peer's redial, admitted through the window first, holds off our relink dial: its proof is on its way. A 2 s
    /// backoff ends inside the 5 s wait for that proof.
    @Test func thePeersAdmittedRedialHoldsOffOurRelinkDial() throws {
        let configuration = LinkManager.Configuration(backoff: ConnectBackoff.Configuration(baseMilliseconds: 2000))
        let rig = LinkRig(local: high, configuration: configuration)
        try closedByTheRadio(rig)
        _ = rig.advance(500)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.radio.dials.isEmpty, "the close's backoff holds")
        let (hello, _) = rig.acceptProving(low, on: ChannelID(101))
        #expect(rig.said("link \(low) relinks out of order on ch101"))
        _ = rig.advance(3000)
        #expect(try #require(rig.links.backoffs[.peer(.node(low))]).nextAt <= rig.clock.monotonicMilliseconds())
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.radio.dials.isEmpty, "past the backoff, a proving dialer is busy")
        let events = try rig.proveDialer(low, on: ChannelID(101), hello: hello)
        #expect(events.contains { if case .up(let neighbor) = $0 { neighbor.nodeId == low } else { false } })
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        #expect(rig.radio.dials.isEmpty, "linked")
    }

    @Test func anotherProvingDialerOfTheSameIdKeepsWeDialIt() throws {
        let rig = LinkRig(local: high)
        try closedByTheRadio(rig)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        _ = rig.acceptProving(low, on: ChannelID(101))
        #expect(rig.said("link \(low) relinks out of order on ch101"))
        _ = rig.acceptProving(low, on: ChannelID(102))
        #expect(rig.radio.closed.contains(ChannelID(102)), "the first dialer's proof is on its way")
        #expect(!rig.radio.closed.contains(ChannelID(101)))
    }

    @Test func refuseLegacyStillComesFirst() throws {
        let keys = FakeKeys()
        let rig = LinkRig.blindingIPhone(keys: keys)
        let peer = BlindingPeer(low)
        _ = try peer.dial(rig, on: ChannelID(61), told: peer.tag(wall: rig.wall))
        _ = rig.handle(.closed(ChannelID(61)))
        #expect(rig.relinkOpen(for: low))
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        let legacy = LinkRig.iPhone(low, withholdsBlindAdvert: true).links.ourHello(addressing: nil)
        _ = rig.handle(.accepted(ChannelID(62)))
        _ = rig.handle(.received(ChannelID(62), required(LinkRecord(.hello, payload: legacy.payload).encoded)))
        #expect(rig.said("link refused \(low): it reads no tags"))
        #expect(rig.radio.writes(on: ChannelID(62)).isEmpty)
        #expect(!rig.said("link \(low) relinks out of order on ch62"))
    }

    /// A held proven link closes the window when it registers, so the two never stand together on air; opened by hand
    /// beside one, the window still yields to `RefuseHeld`.
    @Test func refuseHeldStillComesFirst() throws {
        let keys = FakeKeys()
        let rig = LinkRig.blindingIPhone(keys: keys)
        let peer = BlindingPeer(low)
        _ = try peer.dial(rig, on: ChannelID(61), told: peer.tag(wall: rig.wall))
        rig.links.relinkWindow.radioClosed(low, proven: true, now: rig.clock.monotonicMilliseconds())
        let current = try #require(rig.airedTag)
        _ = rig.handle(.accepted(ChannelID(62)))
        let hello = peer.hello(told: peer.tag(wall: rig.wall), addressed: current)
        _ = rig.handle(.received(ChannelID(62), required(LinkRecord(.hello, payload: hello).encoded)))
        #expect(rig.links.writerCounters.refusedHeld == 1)
        #expect(rig.radio.closed.contains(ChannelID(62)))
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
        #expect(!rig.said("link \(low) relinks out of order on ch62"))
    }

    @Test func aWriteStallsCloseOpensNothing() throws {
        let rig = LinkRig(local: high)
        rig.radio.setLevel(OutboxLevel(queuedBytes: 50_000, writtenBytes: 1000), on: ChannelID(100))
        let (hello, _) = rig.acceptProving(low, on: ChannelID(100))
        _ = try rig.proveDialer(low, on: ChannelID(100), hello: hello)
        let events = rig.run(until: rig.clock.monotonicMilliseconds() + 150_000)
        #expect(events.contains(.down(low)))
        _ = rig.handle(.closed(ChannelID(100)))
        #expect(!rig.relinkOpen(for: low))
    }
}
