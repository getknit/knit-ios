import KnitWire
import Testing

@testable import KnitMesh

/// knit-peer's allow list (`--only-link`, knit-ios #58; ``LinkManager/Configuration/onlyLinks``): every link but the named
/// ones is refused both ways, at admission, before a HELLO's frames reach the engine, and `deny-link` and `allow-link` keep
/// working inside it. Clear peers here; blinded forms in ``LinkAllowListBlindTests``.
@Suite struct LinkAllowListTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high

    private func rig(local: NodeId, only: Set<NodeId>) -> LinkRig {
        var configuration = LinkManager.Configuration()
        configuration.onlyLinks = only
        return LinkRig(local: local, configuration: configuration)
    }

    private func dialedNothing(_ rig: LinkRig) -> Bool {
        rig.radio.dials.isEmpty && !rig.log.all.contains { $0.contains("link dialing") }
    }

    @Test func aDialerOffTheListIsClosedAtItsHelloAndANamedOneLinks() {
        let rig = rig(local: low, only: [high])
        #expect(rig.accept(middle, on: ChannelID(40)).isEmpty)
        #expect(rig.radio.closed == [ChannelID(40)])
        #expect(rig.radio.records(on: ChannelID(40)).isEmpty, "no HELLO back")
        #expect(rig.said("link refused \(middle): not on the allow list"))
        let (_, events) = rig.acceptProving(middle, on: ChannelID(41))
        #expect(events.isEmpty && rig.radio.records(on: ChannelID(41)).isEmpty, "a proving dialer is refused before its proof")
        #expect(rig.links.neighbors.isEmpty, "never registered")
        #expect(rig.accept(high, on: ChannelID(42)).first == .up(Neighbor(nodeId: high, protocolVersion: 1, capabilities: 0xFFF)))
        #expect(rig.links.neighbors.map(\.nodeId) == [high])
        #expect(
            rig.links.liveLinks.first { $0.neighbor.nodeId == high }?.proven == false,
            "a plain claim to a named id links unproven: the gap the issue accepts")
    }

    /// A clear dial to a named id whose reply names an id off the list links nothing: the wrong-peer check closes it ahead of
    /// the list, so only our HELLO reaches the node that answered.
    @Test func aClearDialAnsweredByAnIdOffTheListLinksNothing() throws {
        let rig = rig(local: high, only: [low])
        rig.sightToPromotion(low)
        let dial = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.connected(dial))
        #expect(rig.handle(.received(dial, LinkRig.helloRecord(middle))).isEmpty)
        #expect(rig.radio.closed == [dial])
        #expect(rig.links.neighbors.isEmpty, "never registered")
        #expect(rig.radio.records(on: dial).map(\.tag) == [.hello], "our HELLO alone")
    }

    @Test func aClearSightingOffTheListIsNeverDialedAndANamedOneIs() {
        let rig = rig(local: high, only: [low])
        rig.sightToPromotion(middle)
        #expect(dialedNothing(rig))
        #expect(rig.links.dwellDue(now: rig.clock.monotonicMilliseconds()) == nil, "no dwell to wake for")
        rig.sightToPromotion(low)
        #expect(rig.radio.dials.map(\.address) == [RadioAddress("addr-\(low)")])
    }

    @Test func denyLinkRefusesANamedIdSilentlyAndAllowLinkAdmitsNobodyOffTheList() {
        let rig = rig(local: high, only: [low])
        _ = rig.links.refuse(low)
        rig.sightToPromotion(low)
        #expect(dialedNothing(rig), "deny-link holds inside the list")
        _ = rig.handle(.accepted(ChannelID(50)))
        _ = rig.handle(.received(ChannelID(50), LinkRig.helloRecord(low)))
        #expect(rig.radio.closed == [ChannelID(50)])
        #expect(!rig.log.all.contains { $0.contains("not on the allow list") }, "deny-link's close stays silent")
        _ = rig.links.permit(middle)
        rig.sightToPromotion(middle)
        #expect(rig.radio.dials.isEmpty, "allow-link on an unnamed node lets nothing in")
        #expect(rig.accept(middle, on: ChannelID(51)).isEmpty)
        _ = rig.links.permit(low)
        #expect(rig.radio.dials.map(\.address) == [RadioAddress("addr-\(low)")], "still present and dwelled, so dialed at once")
    }

    @Test func withoutAListEveryoneLinksAsBefore() {
        let rig = LinkRig(local: low)
        #expect(rig.accept(middle, on: ChannelID(60)).first == .up(Neighbor(nodeId: middle, protocolVersion: 1, capabilities: 0xFFF)))
        #expect(!rig.links.refuses(high) && !rig.links.refusesSighting(.node(high)))
    }
}

/// The allow list against blinded adverts: a form held under a handle names no id, so it is never dialed, whichever rule
/// would dial it; a form a key resolves is judged by its id; and a claim is unproven, so a tag dial whose proof names an id
/// off the list closes before our PROOF (``LinkManager/refusedTagDial(_:_:_:now:)``).
@Suite struct LinkAllowListBlindTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle

    private func dialedNothing(_ rig: LinkRig) -> Bool {
        rig.radio.dials.isEmpty && !rig.log.all.contains { $0.contains("link dialing") }
    }

    /// Both forms in range, heard every two seconds for `milliseconds`.
    private func hear(_ rig: LinkRig, _ sightings: [RadioSighting], for milliseconds: Int64) {
        var left = milliseconds
        while true {
            for sighting in sightings {
                _ = rig.handle(.sighted(sighting))
            }
            guard left > 0 else {
                return
            }
            _ = rig.advance(2000)
            left -= 2000
        }
    }

    /// Under our own blinding the order dials a blinded form whose tag sorts below ours (`AdvertOrder.iDial`): a list-less
    /// rig dials it, a rig with a list never does, unresolved or resolved to an id off the list, and dials it once a key
    /// resolves it to a named id.
    @Test func theOrderUnderOurBlindingDialsNoFormTheListDoesNotName() throws {
        let probe = LinkRig.blindingIPhone(keys: FakeKeys())
        let wall = probe.wall
        let ours = probe.links.mine.current
        let found = (UInt8(1)...UInt8(64)).lazy.map { BlindingPeer(LinkRig.low, keyByte: $0) }.first { peer in
            AdvertOrder.iDial(ours, .of(peer.sighting(peer.tag(wall: wall)).advert))
        }
        let below = try #require(found, "a key whose tag sorts below ours")
        let tag = below.tag(wall: wall)

        let open = LinkRig.blindingIPhone(keys: FakeKeys())
        open.hear(below.sighting(tag), for: 14_000)
        #expect(open.radio.dials.count == 1, "the order dials it without a list")

        let listed = LinkRig.blindingIPhone(keys: FakeKeys(), onlyLinks: [middle])
        listed.hear(below.sighting(tag), for: 30_000)
        #expect(dialedNothing(listed), "unresolved")
        listed.links.listPresenceKeys([low: [below.key]])
        listed.hear(below.sighting(tag), for: 30_000)
        #expect(listed.links.sightings().map(\.nodeId) == [low], "resolved by key to an id off the list")
        #expect(dialedNothing(listed))

        let named = LinkRig.blindingIPhone(keys: FakeKeys(), onlyLinks: [low])
        named.links.listPresenceKeys([low: [below.key]])
        named.hear(below.sighting(tag), for: 14_000)
        #expect(named.radio.dials.map(\.address) == [below.address], "resolved to a named id: dialed")
    }

    /// While clear, the head start tag-dials a flagged blinded phone (ADR 2026-10.6eyf, amended by sv5t): never an
    /// unresolved one under a list, and no dwell is woken for it.
    @Test func theHeadStartNeverDialsAnUnresolvedForm() {
        let rig = LinkRig.iPhone(onlyLinks: [low])
        let stranger = BlindingPeer(middle, keyByte: 9)
        rig.hear(stranger.sighting(stranger.tag(wall: rig.clock.wallMilliseconds())), for: 60_000)
        #expect(dialedNothing(rig))
        #expect(rig.links.dwellDue(now: rig.clock.monotonicMilliseconds()) == nil)
        #expect(!rig.log.all.contains { $0.contains("head start over") })
    }

    /// Design-pass constraint 2: the unresolved form is passed over before `keepingOneHeadStart`, so a stronger unresolved
    /// flagged form never takes the one head-start slot from a named one. Without a list the stronger one takes it.
    @Test func aStrongerUnresolvedFormNeverTakesTheHeadStartFromANamedOne() {
        let named = BlindingPeer(low)
        var stranger = BlindingPeer(middle, keyByte: 9)
        stranger.address = RadioAddress("addr-stranger")
        func sightings(_ rig: LinkRig) -> [RadioSighting] {
            let wall = rig.clock.wallMilliseconds()
            return [named.sighting(named.tag(wall: wall), rssi: -60), stranger.sighting(stranger.tag(wall: wall), rssi: -40)]
        }

        let open = LinkRig.iPhone()
        open.links.listPresenceKeys([low: [named.key]])
        hear(open, sightings(open), for: 26_000)
        #expect(open.radio.dials.first?.address == stranger.address, "the strongest takes the slot without a list")

        let listed = LinkRig.iPhone(onlyLinks: [low])
        listed.links.listPresenceKeys([low: [named.key]])
        hear(listed, sightings(listed), for: 26_000)
        #expect(listed.radio.dials.map(\.address) == [named.address])
        #expect(listed.log.all.contains { $0.hasPrefix("info link head start over for \(low) ") })
    }

    /// In the background with no link, seeking dials whatever the order (ADR 2026-10.mueg): never an unresolved form under a
    /// list, and a form a key resolves to a named id at its first sighting.
    @Test func seekingDialsNoUnresolvedForm() {
        let rig = LinkRig.iPhone(background: true, onlyLinks: [low])
        #expect(rig.links.isSeeking)
        let stranger = BlindingPeer(middle, keyByte: 9)
        _ = rig.handle(.sighted(stranger.sighting(stranger.tag(wall: rig.clock.wallMilliseconds()))))
        #expect(dialedNothing(rig))
        var named = BlindingPeer(low)
        named.address = RadioAddress("addr-named")
        rig.links.listPresenceKeys([low: [named.key]])
        _ = rig.handle(.sighted(named.sighting(named.tag(wall: rig.clock.wallMilliseconds()))))
        #expect(rig.radio.dials.map(\.address) == [named.address])
    }

    /// A claim is unproven: `low`'s announced tag, aired after its link ended by `middle` from the same address, resolves
    /// to `low` and is tag-dialed, and the proof names `middle`. The dial closes before our PROOF, `middle` is never
    /// registered, and that tag at that address is not dialed again, nor after `allow-link` for `middle`. Only the list
    /// refuses `middle`, never `deny-link`.
    @Test func aClaimedFormWhoseProofNamesAnIdOffTheListClosesBeforeOurProof() throws {
        let rig = LinkRig.iPhone(onlyLinks: [low])
        let peer = BlindingPeer(low)
        let wall = rig.clock.wallMilliseconds()
        let held = ChannelID(100)
        _ = try peer.dial(rig, on: held, told: peer.tag(wall: wall))
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
        let announced = peer.tag(wall: wall, restart: 1)
        _ = rig.handle(.received(held, BlindingPeer.tagNext(announced)))
        rig.hear(peer.sighting(announced), for: 4000)
        #expect(rig.links.aliases.counters.claims == 1)
        _ = rig.handle(.closed(held))
        #expect(rig.links.neighbors.isEmpty)

        let replayer = BlindingPeer(middle, keyByte: 9)
        rig.hear(replayer.sighting(announced), for: 26_000)
        let dial = try #require(rig.radio.dials.first, "the claim names a listed id, so the tag is dialed")
        _ = rig.handle(.connected(dial.channel))
        let events = try replayer.answer(rig, on: dial.channel, told: announced)
        #expect(events.isEmpty && rig.links.neighbors.isEmpty, "never registered")
        #expect(rig.radio.records(on: dial.channel).map(\.tag) == [.hello], "our HELLO, and no PROOF")
        #expect(rig.radio.closed.contains(dial.channel))
        #expect(rig.log.all.contains { $0.hasSuffix(" proved refused \(middle) on \(dial.channel)") })
        #expect(!rig.links.refused.contains(middle))
        rig.hear(replayer.sighting(announced), for: 30_000)
        #expect(rig.radio.dials.count == 1, "that tag at that address is not dialed again")
        // Design-pass constraint 3: `allow-link` for an id off the list lets nothing in, so the mark stays.
        _ = rig.links.permit(middle)
        #expect(Array(rig.links.refusedDials.values) == [middle])
        #expect(rig.radio.dials.count == 1)
    }
}
