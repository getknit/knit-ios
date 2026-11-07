import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// The link manager reading blinded adverts (knit-next ADR 2026-11.xp6d's reader; ADR 2026-11.sv5t): an iPhone (no service
/// data, a doorbell, at the front unless told) against a scripted blinding Android whose real id, ``LinkRig/low``, sorts
/// below the iPhone's. The tag dial, its failures and their backoff, the held-dial key under a flood, and what is shown.
@Suite struct BlindLinkTests {
    private let low = LinkRig.low
    private let high = LinkRig.high

    /// The iPhone gives the flagged blinding peer its head start, dials its tag, and the link proves `low`.
    private func linkByTag(_ rig: LinkRig, _ peer: BlindingPeer, tag: NodeId) throws -> ChannelID {
        rig.hear(peer.sighting(tag), for: 24_000)
        let dial = try #require(rig.radio.dials.last)
        _ = rig.handle(.connected(dial.channel))
        _ = try peer.answer(rig, on: dial.channel, told: tag)
        return dial.channel
    }

    @Test func aTagDialAddressesTheTagProvesTheIdAndRegistersUnderIt() throws {
        let rig = LinkRig.iPhone()
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        rig.hear(peer.sighting(tag), for: 22_000)
        #expect(rig.radio.dials.isEmpty, "a clear phone never dials a tag by the order: it waits the head start")
        rig.hear(peer.sighting(tag), for: 2000)
        let dial = try #require(rig.radio.dials.first)
        #expect(dial.address == peer.address)
        #expect(rig.said("link dialing ~zzzz…0 on \(dial.channel)"), "the handle, never the tag")
        #expect(rig.log.all.contains { $0.hasPrefix("info link head start over for ~zzzz…0 (dwell=") })
        _ = rig.handle(.connected(dial.channel))
        let ours = Hello(payload: try #require(rig.ourHelloPayload(on: dial.channel)))
        #expect(ours.addressed == tag.bytes, "a = the tag dialed")
        #expect(ours.told == nil, "never a t")
        let events = try peer.answer(rig, on: dial.channel, told: tag)
        #expect(events.contains { if case .up(let neighbor) = $0 { neighbor.nodeId == low } else { false } })
        #expect(rig.said("link ~zzzz…0 proved \(low) on \(dial.channel)"))
        #expect(rig.links.aliasCounters.tagDials == 1 && rig.links.aliasCounters.tagDialsProven == 1)
        #expect(!rig.log.all.contains { $0.contains(tag.string) }, "no line names the tag")
        // The tag is the link's claim now: it shows as the peer, and the held-dial key keeps it from being dialed again.
        rig.hear(peer.sighting(tag), for: 60_000)
        #expect(rig.radio.dials.count == 1)
        #expect(rig.links.sightings().map(\.nodeId) == [low])
    }

    /// `RefuseLegacy`: a blinding phone refuses, with no reply, a dialer whose HELLO lacks the bit, as a build from before
    /// the reader sends. The failure is the tag's and the address's, never the id's.
    @Test func aTagDialFailsWithoutTheBitAndLinksWithIt() throws {
        let rig = LinkRig.iPhone(withholdsBlindAdvert: true)
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        rig.hear(peer.sighting(tag), for: 24_000)
        let dial = try #require(rig.radio.dials.first)
        _ = rig.handle(.connected(dial.channel))
        _ = try peer.answer(rig, on: dial.channel, told: tag)
        #expect(rig.links.neighbors.isEmpty)
        let handle = try #require(rig.links.formKeys.existing(tag))
        let booked = Set(rig.links.backoffs.keys)
        #expect(booked == [.tag(handle, peer.address), .address(peer.address), .peer(.form(handle))])
        #expect(rig.links.backoffs[.peer(.node(low))] == nil)
        let claiming = LinkRig.iPhone()
        _ = try linkByTag(claiming, peer, tag: peer.tag(wall: claiming.clock.wallMilliseconds()))
        #expect(claiming.links.neighbors.map(\.nodeId) == [low])
    }

    /// A reply naming us, one without the proof's bit, one whose PROOF another key signed, a first record that is no HELLO,
    /// and one with the bit but no nonce each fail (`LinkHandshake.dialTag`, `LinkHandshake.kt:134-154`), booked on the dial
    /// key and the address, never on the id the reply named.
    @Test(arguments: [0, 1, 2, 3, 4])
    func aBadReplyFailsTheTagDialOnTheTagAndTheAddress(kind: Int) throws {
        let rig = LinkRig.iPhone()
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        rig.hear(peer.sighting(tag), for: 24_000)
        let dial = try #require(rig.radio.dials.first)
        _ = rig.handle(.connected(dial.channel))
        let ours = try #require(rig.ourHelloPayload(on: dial.channel))
        let reply: [UInt8]
        switch kind {
        case 0:
            reply = required(LinkRecord(.hello, payload: LinkRig.provingHello(high).payload).encoded)
        case 1:
            reply = LinkRig.helloRecord(low)
        case 3:
            reply = BlindingPeer.tagNext(tag)
        case 4:
            reply = required(LinkRecord(.hello, payload: Hello(nodeId: low.string, capabilities: Capabilities.local).payload).encoded)
        default:
            let hello = peer.hello(told: tag)
            let forged = try LinkRig.proofRecord(LinkRig.keys(of: LinkRig.middle), as: .responder, dialerHello: ours, responderHello: hello)
            reply = required(LinkRecord(.hello, payload: hello).encoded) + forged
        }
        _ = rig.handle(.received(dial.channel, reply))
        #expect(rig.links.neighbors.isEmpty)
        #expect(rig.radio.closed.contains(dial.channel))
        let handle = try #require(rig.links.formKeys.existing(tag))
        #expect(rig.links.backoffs[.tag(handle, peer.address)]?.streak == 1)
        #expect(rig.links.backoffs[.address(peer.address)]?.streak == 1)
        #expect(rig.links.backoffs[.peer(.node(low))] == nil && rig.links.backoffs[.peer(.node(high))] == nil)
        #expect(rig.said("link \(dial.channel) proof failed for \(low): unproven") == (kind == 1))
        #expect(rig.said("link \(dial.channel) proof failed for \(low): nonce") == (kind == 4))
    }

    /// Design-pass finding 1: a refusing phone's tag backs off 10, 20, 40, 80 and 160 s, its streak growing on the dial key
    /// rather than pruned each time its wait runs out (the hj4a 158-dials class).
    @Test func aTagRefusedFiveTimesBacksOffDoublingEachTime() throws {
        var configuration = LinkManager.Configuration()
        configuration.backoff = ConnectBackoff.Configuration(jitterFraction: 0)
        // Withheld, so the blinding peer refuses every dial as legacy (`RefuseLegacy`).
        configuration.withholdsBlindAdvert = true
        let rig = LinkRig(local: high, advertisesServiceData: false, servesDoorbell: true, configuration: configuration)
        // Unflagged: it reads no GATT payload, so the iPhone dials it on the ordinary dwell, whatever the order.
        let peer = BlindingPeer(low, flags: 0)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        var waits: [Int64] = []
        rig.hear(peer.sighting(tag), for: 12_000)
        for attempt in 1...5 {
            let dial = try #require(rig.radio.dials.last)
            #expect(rig.radio.dials.count == attempt)
            _ = rig.handle(.connected(dial.channel))
            _ = try peer.answer(rig, on: dial.channel, told: tag)
            let handle = try #require(rig.links.formKeys.existing(tag))
            let booked = try #require(rig.links.backoffs[.tag(handle, peer.address)])
            #expect(booked.streak == attempt)
            waits.append(booked.nextAt - rig.clock.monotonicMilliseconds())
            rig.hear(peer.sighting(tag), for: booked.nextAt - rig.clock.monotonicMilliseconds() + 2000)
        }
        #expect(waits == [10_000, 20_000, 40_000, 80_000, 160_000])
    }

    /// The reviewer's second finding on phase 2a: a flood of fresh tags inside one sighting gap of a held peer never takes
    /// the held-dial key's handle, so the held phone's next sighting is not dialed again (on an iPhone the safety net would
    /// replace the link once per eviction).
    @Test func aTagFloodInsideAHeldPeersGapNeitherRedialsItNorPassesTheCap() throws {
        let rig = LinkRig.iPhone()
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        let channel = try linkByTag(rig, peer, tag: tag)
        let handle = try #require(rig.links.formKeys.existing(tag))
        var fixture = BlindFixture()
        let stranger = required(NodeId(bytes: [UInt8](repeating: 9, count: NodeId.byteCount)))
        let hmacs = rig.links.aliases.counters.tableHmacs
        for index in 0..<600 {
            let fresh = BlindFixture.tag(fixture.key(), owner: stranger, slot: 1)
            var flooder = peer
            flooder.address = RadioAddress("flood-\(index)")
            _ = rig.handle(.sighted(flooder.sighting(fresh)))
        }
        #expect(rig.links.aliases.counters.tableHmacs == hmacs, "a flood costs no HMACs")
        #expect(rig.links.formKeys.count == FormKeys.defaultCap, "at most 512 handles")
        #expect(rig.links.aliasCounters.unresolvedForms == FormKeys.defaultCap)
        #expect(rig.links.formKeys.existing(tag) == handle, "the held dial's handle stands")
        #expect(rig.links.sightings().map(\.nodeId) == [low], "no tag shows as a peer")
        _ = rig.hear(peer.sighting(tag), for: 2000)
        #expect(rig.radio.dials.count == 1)
        #expect(rig.links.liveChannel(to: low) == channel)
    }

    /// Design-pass finding 2: a locked hour leaves several announcements waiting on the link, read back to back; only the
    /// newest reaches the resolver, which then names the rotated tag as the link's once it is heard.
    @Test func theNewestOfATagNextBacklogIsTakenAndItsTagResolvesWhenHeard() throws {
        let rig = LinkRig.iPhone()
        let peer = BlindingPeer(low)
        let wall = rig.clock.wallMilliseconds()
        let channel = try linkByTag(rig, peer, tag: peer.tag(wall: wall))
        let announced = (1...3).map { peer.tag(wall: wall, restart: $0) } + [peer.tag(wall: wall + BlindTag.slotMilliseconds, restart: 1)]
        _ = rig.handle(.received(channel, announced.flatMap(BlindingPeer.tagNext)))
        #expect(rig.links.aliasCounters.tagNextTaken == 1)
        #expect(rig.links.aliases.counters.pending == 1)
        // The newest, heard: the link's claim, so the rotation costs no redial.
        _ = rig.hear(peer.sighting(announced[3]), for: 30_000)
        #expect(rig.links.aliases.counters.claims == 1 && rig.links.aliases.counters.pending == 0, "now the link's claim")
        #expect(rig.radio.dials.count == 1)
        #expect(rig.links.sightings().map(\.nodeId) == [low])
        // A second inside the 120 s window is refused by the rate limit.
        _ = rig.handle(.received(channel, BlindingPeer.tagNext(announced[1])))
        #expect(rig.links.aliasCounters.tagNextRefused == 1)
    }

    /// A `TAG_NEXT` on a link whose HELLO lacks ``Capabilities/blindAdvert`` is dropped and counted.
    @Test func aTagNextFromAPeerWithoutTheBitIsRefused() throws {
        let rig = LinkRig.iPhone()
        let withoutTheBit = Capabilities.local.union(.blobHave).subtracting(.blindAdvert)
        let (hello, _) = rig.acceptProving(LinkRig.middle, on: ChannelID(100), capabilities: withoutTheBit)
        _ = try rig.proveDialer(LinkRig.middle, on: ChannelID(100), hello: hello)
        #expect(rig.links.neighbors.count == 1)
        _ = rig.handle(.received(ChannelID(100), BlindingPeer.tagNext(BlindingPeer(low).tag(wall: rig.clock.wallMilliseconds()))))
        #expect(rig.links.aliasCounters.tagNextRefused == 1 && rig.links.aliasCounters.tagNextTaken == 0)
        #expect(rig.links.neighbors.count == 1, "the link stays")
    }

    /// The responder honours a proving dialer's `t` and `a`, so a blinding Android whose real id sorts below ours is
    /// admitted even when a contact's key sights it. Its `t` is a hint for the link.
    @Test func theResponderAdmitsABlindingDialerWhoseIdSortsBelowEvenWhenAKeySightsIt() throws {
        let rig = LinkRig.iPhone()
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        rig.links.listPresenceKeys([low: [peer.key]])
        _ = rig.handle(.sighted(peer.sighting(tag)))
        #expect(rig.links.sightings().map(\.nodeId) == [low], "resolved by key from the first sighting")
        #expect(rig.links.aliasCounters.resolvedByKey == 1)
        let events = try peer.dial(rig, on: ChannelID(100), told: tag)
        #expect(events.contains { if case .up(let neighbor) = $0 { neighbor.nodeId == low } else { false } })
        #expect(!rig.log.all.contains { $0.contains("refused") })
    }

    /// ADR 2026-11.sv5t's departure: a tag a held link hinted holds off our dial, head start included, where Android's
    /// hint holds off nothing.
    @Test func noHeadStartGoesToATagAHeldLinkHinted() throws {
        let rig = LinkRig.iPhone()
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        _ = try peer.dial(rig, on: ChannelID(100), told: tag)
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
        rig.hear(peer.sighting(tag), for: 40_000)
        #expect(rig.radio.dials.isEmpty)
        #expect(rig.links.aliases.counters.resolvedByHint > 0)
        #expect(rig.links.sightings().map(\.nodeId) == [low], "the link's peer is sighted, so its link is not shed first")
    }

    /// The safety net: an unannounced rotation leaves the new tag unresolved, and the iPhone's tag dial to it proves an id
    /// it already holds a proven link to. The new link stays and the old one goes, so the engine sees `.down` then `.up`.
    @Test func aTagDialProvingAHeldIdReplacesTheHeldLink() throws {
        let rig = LinkRig.iPhone()
        let peer = BlindingPeer(low)
        let wall = rig.clock.wallMilliseconds()
        _ = try peer.dial(rig, on: ChannelID(100), told: peer.tag(wall: wall))
        let rotated = peer.tag(wall: wall, restart: 1)
        rig.hear(peer.sighting(rotated), for: 24_000)
        let dial = try #require(rig.radio.dials.first, "the unannounced tag, at the front, waits the head start, then dials")
        _ = rig.handle(.connected(dial.channel))
        let events = try peer.answer(rig, on: dial.channel, told: rotated)
        let downs = events.filter { $0 == .down(low) }
        #expect(downs.count == 1)
        #expect(events.firstIndex(of: .down(low)) ?? .max < events.firstIndex { if case .up = $0 { true } else { false } } ?? -1)
        #expect(rig.said("link \(low) replaced its stale link \(ChannelID(100)) with \(dial.channel)"))
        #expect(rig.links.liveChannel(to: low) == dial.channel)
    }

    /// The reviewer's third finding on phase 2a: a tag dial that proves a refused id registers nothing, and the resolver
    /// hears only the proof (`onDialProved`), never a claim for a link that does not stand.
    @Test func aProvenTagDialToARefusedIdRegistersNothing() throws {
        let rig = LinkRig.iPhone()
        _ = rig.links.refuse(low)
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        rig.hear(peer.sighting(tag), for: 24_000)
        let dial = try #require(rig.radio.dials.first, "an unresolved form names no id to refuse")
        _ = rig.handle(.connected(dial.channel))
        let events = try peer.answer(rig, on: dial.channel, told: tag)
        #expect(events.isEmpty && rig.links.neighbors.isEmpty)
        #expect(rig.links.aliases.counters.claims == 0 && rig.links.aliases.counters.heldLinks == 0)
        #expect(rig.links.heldDials.isEmpty)
    }

    /// In the background with no link, seeking dials a tag on its first sighting, and the link proves.
    @Test func seekingDialsATagOnOneSighting() throws {
        let rig = LinkRig.iPhone(background: true)
        #expect(rig.links.isSeeking)
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        _ = rig.handle(.sighted(peer.sighting(tag)))
        let dial = try #require(rig.radio.dials.first)
        _ = rig.handle(.connected(dial.channel))
        _ = try peer.answer(rig, on: dial.channel, told: tag)
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
    }

    /// Design-pass finding 8 (the bb1e749 shape): a tag's 24 s head-start dwell ending between its adverts dials at the
    /// deadline, not at the next advert.
    @Test func aTagsDwellEndingBetweenAdvertsDialsAtTheDeadline() {
        let rig = LinkRig.iPhone()
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        let first = rig.clock.monotonicMilliseconds()
        _ = rig.hear(peer.sighting(tag), for: 20_000)
        #expect(rig.links.nextDeadline == first + 24_000)
        rig.run(until: first + 24_000)
        #expect(rig.radio.dials.count == 1)
    }

    /// A clear dial's HELLO names the id dialed (`a`), as every Android build writes it.
    @Test func aClearDialAddressesTheIdItDialed() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let dial = try #require(rig.radio.dials.first)
        _ = rig.handle(.connected(dial.channel))
        #expect(Hello(payload: try #require(rig.ourHelloPayload(on: dial.channel))).addressed == low.bytes)
        #expect(rig.said("link dialing \(low) on \(dial.channel)"), "the harness's line, byte for byte")
    }
}
