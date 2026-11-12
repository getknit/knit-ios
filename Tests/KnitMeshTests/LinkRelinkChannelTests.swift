import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// Which other channels the relink window's guard reads (``LinkManager/attemptsLink(to:besides:)``): a channel some other
/// dialer opened, and a live link to another peer, never hold a relink back; our tag dial whose tag resolves to the
/// relinking id now does, though the dial went out unresolved.
@Suite struct LinkRelinkChannelTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high

    /// `low` dials `rig` unsighted on `id`, proves itself, and the radio then closes the link: the window opens.
    private func closedByTheRadio(_ rig: LinkRig, on id: ChannelID = ChannelID(100)) throws {
        let (hello, _) = rig.acceptProving(low, on: id)
        _ = try rig.proveDialer(low, on: id, hello: hello)
        _ = rig.handle(.closed(id))
        #expect(rig.relinkOpen(for: low))
    }

    /// `low`, sighted, redials `rig` proving itself on `id`: whether we answered.
    private func sightedRedial(_ rig: LinkRig, on id: ChannelID) -> Bool {
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        _ = rig.acceptProving(low, on: id)
        return !rig.radio.closed.contains(id)
    }

    @Test func aChannelAnotherDialerOpenedDoesNotHoldTheRelinkBack() throws {
        let rig = LinkRig(local: high)
        try closedByTheRadio(rig)
        // One dialer still owes its HELLO; another proves a different id.
        _ = rig.handle(.accepted(ChannelID(101)))
        _ = rig.acceptProving(middle, on: ChannelID(102))
        #expect(sightedRedial(rig, on: ChannelID(103)))
        #expect(rig.said("link \(low) relinks out of order on ch103"))
    }

    @Test func aLiveLinkToAnotherPeerDoesNotHoldTheRelinkBack() throws {
        let rig = LinkRig(local: high)
        let (hello, _) = rig.acceptProving(middle, on: ChannelID(90))
        _ = try rig.proveDialer(middle, on: ChannelID(90), hello: hello)
        #expect(rig.links.neighbors.map(\.nodeId) == [middle])
        try closedByTheRadio(rig)
        #expect(sightedRedial(rig, on: ChannelID(101)))
        #expect(rig.said("link \(low) relinks out of order on ch101"))
    }

    /// Our head start goes to a tag nothing resolves, so the dial names no id; a key listed meanwhile resolves that tag to
    /// the relinking id, so the dial is an attempt to link it after all.
    @Test func ourTagDialWhoseTagNowResolvesToTheIdKeepsWeDialIt() throws {
        let rig = LinkRig.iPhone()
        try closedByTheRadio(rig)
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: rig.wall)
        let closed = rig.clock.monotonicMilliseconds()
        rig.hear(peer.sighting(tag), for: 24_000)
        let dial = try #require(rig.radio.dials.last, "the head start ran out")
        #expect(rig.said("link dialing ~zzzz…0 on \(dial.channel)"), "dialed unresolved, by its handle")
        rig.links.listPresenceKeys([low: [peer.key]])
        #expect(rig.links.aliases.standing(tag)?.nodeId == low)
        #expect(rig.clock.monotonicMilliseconds() - closed < 30_000)
        _ = rig.handle(.sighted(LinkRig.sighting(low)))
        let hello = peer.hello(told: nil, addressed: high)
        _ = rig.handle(.accepted(ChannelID(101)))
        _ = rig.handle(.received(ChannelID(101), required(LinkRecord(.hello, payload: hello).encoded)))
        #expect(rig.radio.closed.contains(ChannelID(101)))
        #expect(rig.said("link refused \(low): we dial it"))
        #expect(!rig.radio.closed.contains(dial.channel), "our dial goes on")
    }
}
