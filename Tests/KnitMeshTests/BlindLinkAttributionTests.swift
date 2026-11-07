import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// The link manager reading blinded adverts, beside `BlindLinkTests` (knit-next ADR 2026-11.xp6d's reader; ADR 2026-11.sv5t):
/// what a tag dial's proof does to the links already held, what a sighting is attributed to once a replay is marked, and
/// whom seeking passes over. The same iPhone against a scripted blinding Android whose real id, ``LinkRig/low``, sorts
/// below the iPhone's.
@Suite struct BlindLinkAttributionTests {
    private let low = LinkRig.low

    /// R3 on a tag dial (`provedTagDial`): an unproven link claiming the id our tag dial proves is displaced, so the engine
    /// sees `.down` then `.up`, and the proven link is the one held.
    @Test func aTagDialProvingAnIdDisplacesTheUnprovenLinkClaimingIt() throws {
        let rig = LinkRig.iPhone()
        let peer = BlindingPeer(low)
        _ = rig.accept(low, on: ChannelID(100), capabilities: Capabilities.local.subtracting(.linkProof))
        #expect(rig.links.neighbors.map(\.nodeId) == [low], "a legacy claim, unproven")
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        rig.hear(peer.sighting(tag), for: 24_000)
        let dial = try #require(rig.radio.dials.first, "an unresolved tag names no id the link could hold off")
        _ = rig.handle(.connected(dial.channel))
        let events = try peer.answer(rig, on: dial.channel, told: tag)
        #expect(rig.said("link \(ChannelID(100)) displaced: \(low) proved itself on \(dial.channel)"))
        #expect(events.first == .down(low))
        #expect(events.contains { if case .up(let neighbor) = $0 { neighbor.nodeId == low } else { false } })
        #expect(rig.radio.closed.contains(ChannelID(100)))
        #expect(rig.links.liveChannel(to: low) == dial.channel)
        #expect(rig.said("link ~zzzz…0 proved \(low) on \(dial.channel)"))
    }

    /// A blinded advert whose bytes lack the tag prefix is malformed (`AdvertAliases.resolve`'s first rule): it is never
    /// sighted, gets no handle, and is never dialed.
    @Test func aBlindedAdvertWithoutTheTagPrefixIsNeverSightedOrDialed() {
        let rig = LinkRig.iPhone()
        let malformed = BlindFixture.id("malformed")
        #expect(!AdvertForm.hasTagPrefix(malformed.bytes))
        rig.hear(BlindingPeer(low).sighting(malformed), for: 40_000)
        #expect(rig.radio.dials.isEmpty)
        #expect(rig.links.sightings().isEmpty)
        #expect(rig.links.aliasCounters.tagsHeard == 0 && rig.links.aliasCounters.unresolvedForms == 0)
        #expect(rig.links.aliases.counters.malformed > 0)
    }

    /// `BlindReaderTest.aReplayersProvenDialHoldsOffNoContactAtTheContactsAddress`: a replayer airing a contact's tag
    /// proves its own id on our tag dial. The key outranks the proof, the pair of tag and address is marked a replay, so the
    /// replayer's sightings attribute nothing, and the contact airing the tag from her own address is dialed as herself.
    @Test func aReplayersProvenTagDialHoldsOffNoContactAtTheContactsAddress() throws {
        let rig = LinkRig.iPhone()
        let contact = BlindingPeer(low)
        let tag = contact.tag(wall: rig.clock.wallMilliseconds())
        rig.links.listPresenceKeys([low: [contact.key]])
        var replayer = BlindingPeer(LinkRig.middle, keyByte: 9)
        replayer.address = RadioAddress("addr-replayer")
        rig.hear(replayer.sighting(tag), for: 24_000)
        let dial = try #require(rig.radio.dials.first)
        #expect(dial.address == replayer.address)
        _ = rig.handle(.connected(dial.channel))
        _ = try replayer.answer(rig, on: dial.channel, told: tag)
        #expect(rig.links.aliasCounters.keyProofMismatches == 1)
        #expect(rig.links.neighbors.map(\.nodeId) == [LinkRig.middle], "the replayer is linked as itself")
        let seen = try #require(rig.links.sightings().first { $0.nodeId == low }).lastSeenAgoMilliseconds
        rig.hear(replayer.sighting(tag), for: 10_000)
        #expect(rig.radio.dials.count == 1, "the replayer's address is held off, as the device it is")
        let since = try #require(rig.links.sightings().first { $0.nodeId == low }).lastSeenAgoMilliseconds
        #expect(since == seen + 10_000, "its sightings are the contact's no more")
        rig.hear(contact.sighting(tag), for: 24_000)
        let second = try #require(rig.radio.dials.last)
        #expect(rig.radio.dials.count == 2 && second.address == contact.address, "the contact's own address")
    }

    /// In the background, seeking dials whatever the order, but never a tag a key resolves to a peer whose dial of us is
    /// awaiting its proof, as it never dials a clear peer then (``LinkManager/busy``): the link is on its way.
    @Test func seekingNeverDialsATagWhosePeerIsProvingItsDialOfUs() throws {
        let rig = LinkRig.iPhone(background: true)
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        rig.links.listPresenceKeys([low: [peer.key]])
        let hello = peer.hello(told: tag, addressed: rig.links.localId)
        _ = rig.handle(.accepted(ChannelID(100)))
        _ = rig.handle(.received(ChannelID(100), required(LinkRecord(.hello, payload: hello).encoded)))
        #expect(rig.links.provingDialers == [low])
        _ = rig.handle(.sighted(peer.sighting(tag)))
        #expect(rig.radio.dials.isEmpty, "its proof is on its way")
        let events = try rig.proveDialer(low, on: ChannelID(100), hello: hello)
        #expect(events.contains { if case .up(let neighbor) = $0 { neighbor.nodeId == low } else { false } })
        _ = rig.handle(.sighted(peer.sighting(tag)))
        #expect(rig.radio.dials.isEmpty)
    }
}
