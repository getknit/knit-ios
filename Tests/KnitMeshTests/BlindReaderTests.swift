import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// `BlindReaderTest.kt`'s Sybil (`:207-361`) and held-dial (`:363-635`) cases at knit-next `cad69c77b`, on an iPhone's link
/// manager (knit-next ADR 2026-11.xp6d's reader; ADR 2026-11.sv5t). Android's cases drive its transport's asynchronous
/// worker; these drive the same rules through ``LinkRig`` with scripted blinding peers: a contact (``LinkRig/low``) and a
/// Sybil (``LinkRig/middle``) that links to us and claims tags.
@Suite struct BlindReaderTests {
    private let low = LinkRig.low

    private var contact: BlindingPeer { BlindingPeer(LinkRig.low) }

    private var sybil: BlindingPeer {
        var peer = BlindingPeer(LinkRig.middle, keyByte: 8)
        peer.address = RadioAddress("addr-sybil")
        return peer
    }

    /// A stranger nobody lists a key for, airing from its own address.
    private func stranger(_ byte: UInt8, at address: String) -> BlindingPeer {
        var peer = BlindingPeer(LinkRig.low, keyByte: byte)
        peer.address = RadioAddress(address)
        return peer
    }

    /// `peer` dials us on `channel` and proves itself, telling its own tag.
    private func linkIn(_ rig: LinkRig, _ peer: BlindingPeer, on channel: ChannelID) throws {
        _ = try peer.dial(rig, on: channel, told: peer.tag(wall: rig.clock.wallMilliseconds()))
        #expect(rig.links.liveChannel(to: peer.id) == channel)
    }

    /// The dials that went to `address`.
    private static func dials(_ rig: LinkRig, to address: RadioAddress) -> Int {
        rig.radio.dials.count { $0.address == address }
    }

    // MARK: Sybils (`:207-361`)

    @Test func aContactsKeyOutranksASybilsClaimSoOurDialToTheContactStands() throws {
        let rig = LinkRig.iPhone()
        let tag = contact.tag(wall: rig.clock.wallMilliseconds())
        rig.links.listPresenceKeys([low: [contact.key]])
        try linkIn(rig, sybil, on: ChannelID(100))
        _ = rig.handle(.received(ChannelID(100), BlindingPeer.tagNext(tag)))
        #expect(rig.links.aliases.counters.claimsDropped == 1, "the key contradicts the claim")
        rig.hear(contact.sighting(tag), for: 24_000)
        #expect(Self.dials(rig, to: contact.address) == 1)
    }

    @Test func aKeyThatArrivesAfterASybilsClaimFreesOurDialToTheContact() throws {
        let rig = LinkRig.iPhone()
        let tag = contact.tag(wall: rig.clock.wallMilliseconds())
        try linkIn(rig, sybil, on: ChannelID(100))
        _ = rig.handle(.received(ChannelID(100), BlindingPeer.tagNext(tag)))
        rig.hear(contact.sighting(tag), for: 30_000)
        #expect(rig.radio.dials.isEmpty, "the claimant's link is held")
        rig.links.listPresenceKeys([low: [contact.key]])
        rig.hear(contact.sighting(tag), for: 26_000)
        #expect(Self.dials(rig, to: contact.address) == 1, "one dial: no stale entry under the Sybil's id")
        #expect(rig.links.aliases.counters.claims == 0)
    }

    /// Kotlin's `aStrangersTagClaimedByTagNext…` and `…ToldInATagDialsAnswer…` share one walk (`:260-276`).
    @Test(arguments: [false, true])
    func aStrangersTagClaimedHoldsOffOurDialOnlyWhileTheLinkIsHeld(byTagDial: Bool) throws {
        let rig = LinkRig.iPhone()
        let target = stranger(9, at: "addr-stranger")
        let strangers = target.tag(wall: rig.clock.wallMilliseconds())
        let held: ChannelID
        if byTagDial {
            // We dial the Sybil's tag and its reply tells the stranger's: a rotation edge, held pending, not believed.
            let own = sybil.tag(wall: rig.clock.wallMilliseconds())
            rig.hear(sybil.sighting(own), for: 24_000)
            held = try #require(rig.radio.dials.last?.channel)
            _ = rig.handle(.connected(held))
            _ = try sybil.answer(rig, on: held, told: strangers)
            #expect(rig.links.aliases.counters.pending == 1 && rig.links.aliases.counters.claims == 0)
        } else {
            held = ChannelID(100)
            try linkIn(rig, sybil, on: held)
            _ = rig.handle(.received(held, BlindingPeer.tagNext(strangers)))
        }
        let before = rig.radio.dials.count
        rig.hear(target.sighting(strangers), for: 30_000)
        #expect(rig.radio.dials.count == before, "held off while the claimant's link is held")
        #expect(rig.links.aliases.counters.claims == 1 && rig.links.aliases.counters.pending == 0, "its claim once first heard")
        _ = rig.handle(.closed(held))
        rig.hear(target.sighting(strangers), for: 26_000)
        #expect(Self.dials(rig, to: target.address) == 1, "the link ended: the dial goes")
    }

    @Test func aSybilThatRelinksHoldsOffNoDialAndThatDialsProofVoidsItsClaim() throws {
        let rig = LinkRig.iPhone()
        let strangers = contact.tag(wall: rig.clock.wallMilliseconds())
        try linkIn(rig, sybil, on: ChannelID(100))
        _ = rig.handle(.received(ChannelID(100), BlindingPeer.tagNext(strangers)))
        _ = rig.handle(.sighted(contact.sighting(strangers)))
        _ = rig.handle(.closed(ChannelID(100)))
        try linkIn(rig, sybil, on: ChannelID(101))
        rig.hear(contact.sighting(strangers), for: 26_000)
        let dial = try #require(rig.radio.dials.first { $0.address == contact.address }, "a relinked Sybil holds off nothing")
        _ = rig.handle(.connected(dial.channel))
        _ = try contact.answer(rig, on: dial.channel, told: strangers)
        #expect(rig.links.liveChannel(to: low) == dial.channel)
        #expect(rig.links.aliases.counters.claimsVoided > 0, "the dial's proof voids the liar")
        #expect(rig.links.aliases.standing(strangers)?.nodeId == low)
    }

    @Test func twoSybilIdsClaimingOneTagVoidEachOtherAndNothingHoldsOffOurDial() throws {
        let rig = LinkRig.iPhone()
        let target = stranger(9, at: "addr-stranger")
        let strangers = target.tag(wall: rig.clock.wallMilliseconds())
        var second = BlindingPeer(LinkRig.low, keyByte: 10)
        second.address = RadioAddress("addr-second")
        try linkIn(rig, sybil, on: ChannelID(100))
        try linkIn(rig, second, on: ChannelID(101))
        _ = rig.handle(.received(ChannelID(100), BlindingPeer.tagNext(strangers)))
        _ = rig.handle(.received(ChannelID(101), BlindingPeer.tagNext(strangers)))
        #expect(rig.links.aliases.counters.voided == 1)
        rig.hear(target.sighting(strangers), for: 24_000)
        #expect(Self.dials(rig, to: target.address) == 1)
    }

    @Test func aSybilOnOneLinkHoldsOneClaimSoItHoldsOffOnePhoneAtATime() throws {
        let rig = LinkRig.iPhone()
        let first = stranger(9, at: "addr-first")
        let next = stranger(10, at: "addr-next")
        let wall = rig.clock.wallMilliseconds()
        try linkIn(rig, sybil, on: ChannelID(100))
        _ = rig.handle(.received(ChannelID(100), BlindingPeer.tagNext(first.tag(wall: wall))))
        rig.hear(first.sighting(first.tag(wall: wall)), for: 30_000)
        #expect(rig.radio.dials.isEmpty)
        rig.clock.advance(AdvertAliases<ChannelID>.Configuration().tagNextMinIntervalMilliseconds)
        _ = rig.handle(.received(ChannelID(100), BlindingPeer.tagNext(next.tag(wall: wall))))
        _ = rig.handle(.sighted(next.sighting(next.tag(wall: wall))))
        rig.hear(first.sighting(first.tag(wall: wall)), for: 26_000)
        #expect(Self.dials(rig, to: first.address) == 1, "its new claim replaced the old one, which holds off nothing")
        #expect(Self.dials(rig, to: next.address) == 0)
    }

    // MARK: Held dials (`:363-635`)

    /// The 158-dials class: a link our tag dial proved, its tag heard at once and again after `register`'s own
    /// `promote`, is neither dialed again nor refused into a zero-wait loop.
    @Test func ourOwnProvenTagDialHoldsOffTheRedialAndBooksNothing() throws {
        let rig = LinkRig.iPhone()
        let tag = contact.tag(wall: rig.clock.wallMilliseconds())
        rig.hear(contact.sighting(tag), for: 24_000)
        let dial = try #require(rig.radio.dials.first)
        _ = rig.handle(.connected(dial.channel))
        _ = try contact.answer(rig, on: dial.channel, told: tag)
        _ = rig.handle(.sighted(contact.sighting(tag)))
        rig.hear(contact.sighting(tag), for: 40_000)
        #expect(rig.radio.dials.count == 1)
        #expect(rig.links.backoffs.isEmpty, "no refused dial booked anything")
    }

    /// `theHeldDialCoversOnlyTheAddressItReached`: with no claim to answer for it (the reply told no `t`), the held-dial
    /// key holds off the tag at the address our dial reached, and the same tag at another address is dialed.
    @Test func theHeldDialCoversOnlyTheAddressItReached() throws {
        let rig = LinkRig.iPhone()
        let tag = contact.tag(wall: rig.clock.wallMilliseconds())
        rig.hear(contact.sighting(tag), for: 24_000)
        let dial = try #require(rig.radio.dials.first)
        _ = rig.handle(.connected(dial.channel))
        _ = try contact.answer(rig, on: dial.channel, told: nil)
        rig.hear(contact.sighting(tag), for: 30_000)
        #expect(rig.radio.dials.count == 1, "the same tag at the same address")
        var elsewhere = contact
        elsewhere.address = RadioAddress("addr-elsewhere")
        rig.hear(elsewhere.sighting(tag), for: 26_000)
        #expect(Self.dials(rig, to: elsewhere.address) >= 1, "another address still dials")
    }

    /// `aRefusedDialThatBeganWithItsPeerHeldBacksOff`, then `aStreakEarnedWhileALinkHeldDoesNotHoldOffTheRelink` and its
    /// converse (knit-next ADR 2026-09.hj4a's amendment): a dial to a contact held on an unproven link is refused and backs
    /// off; once that link ends past 15 s the streak goes, and sooner it stands.
    @Test(arguments: [false, true])
    func aDialRefusedWhileItsPeerWasHeldBacksOffAndTheLinksEndClearsItOnlyPast15s(heldLong: Bool) throws {
        let rig = LinkRig.iPhone(claimsBlindAdvert: false)
        let peer = BlindingPeer(LinkRig.low, flags: 0)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        _ = rig.accept(low, on: ChannelID(100))
        #expect(rig.links.liveChannel(to: low) == ChannelID(100), "held, unproven")
        rig.links.listPresenceKeys([low: [peer.key]])
        rig.hear(peer.sighting(tag), for: 12_000)
        let dial = try #require(rig.radio.dials.first, "a key's answer holds off only through a proven link")
        _ = rig.handle(.connected(dial.channel))
        _ = try peer.answer(rig, on: dial.channel, told: tag)
        let handle = try #require(rig.links.formKeys.existing(tag))
        let key = DialKey.tag(handle, peer.address)
        #expect(rig.links.backoffs[key]?.streak == 1, "a dial that began held backs off as a refusal")
        rig.clock.advance(heldLong ? 4000 : 0)
        _ = rig.handle(.closed(ChannelID(100)))
        #expect((rig.links.backoffs[key] == nil) == heldLong)
    }

    // MARK: Keys and clocks

    /// A contact's key resolves its tag from the first sighting, at each slot of the window and across a slot edge, and a
    /// clock off by more than the window does not resolve.
    @Test func aContactsKeyResolvesAcrossTheSlotEdgeAndTheWindowButNotPastIt() {
        let rig = LinkRig.iPhone()
        let peer = contact
        rig.links.listPresenceKeys([low: [peer.key]])
        let wall = rig.clock.wallMilliseconds()
        let slot = BlindTag.slotOf(wallMilliseconds: wall)
        let phase = wall - slot * BlindTag.slotMilliseconds
        for offset in [-32, 0, 2] as [Int64] {
            let tag = BlindFixture.tag(peer.key, owner: low, slot: slot + offset)
            #expect(rig.links.aliases.standing(tag)?.nodeId == low, "slot \(offset)")
        }
        // A sender 46 min ahead or 9 h behind, the slot's phase pinned: three slots ahead, or 36 behind.
        let ahead = BlindTag.slotOf(wallMilliseconds: wall + 46 * 60_000) - slot
        let behind = BlindTag.slotOf(wallMilliseconds: wall - 9 * 3_600_000) - slot
        #expect(phase < 14 * 60_000 ? ahead == 3 : ahead == 4)
        #expect(behind == -36)
        for skewed in [wall + 46 * 60_000, wall - 9 * 3_600_000] {
            _ = rig.handle(.sighted(peer.sighting(peer.tag(wall: skewed))))
        }
        #expect(rig.links.sightings().isEmpty, "a skewed clock links as a stranger")
        // Across the edge: the next slot's tag resolves at once.
        rig.clock.advance(BlindTag.slotMilliseconds - phase)
        _ = rig.links.advance()
        _ = rig.handle(.sighted(peer.sighting(peer.tag(wall: rig.clock.wallMilliseconds()))))
        #expect(rig.links.sightings().map(\.nodeId) == [low])
    }

    /// A key that arrives late carries the dwell its tag gathered unresolved to the contact's id.
    @Test func aKeyArrivingLateCarriesTheDwell() throws {
        let rig = LinkRig.iPhone()
        let tag = contact.tag(wall: rig.clock.wallMilliseconds())
        rig.hear(contact.sighting(tag), for: 10_000)
        #expect(rig.links.sightings().isEmpty)
        rig.links.listPresenceKeys([low: [contact.key]])
        _ = rig.handle(.sighted(contact.sighting(tag)))
        let snapshot = try #require(rig.links.sightings().first)
        #expect(snapshot.key == .node(low))
        #expect(snapshot.dwellMilliseconds >= 10_000)
    }
}

extension MeshTests {
    /// The seam phase 3 drives: a key handed to the actor reaches the radio's resolver, so the contact's tag resolves from
    /// its first sighting (ADR 2026-11.sv5t); and a gain the key limiter holds applies when its minute ends by the timer
    /// alone, the timer re-aimed at it when the listing came (ADR 2026-09.gq84).
    @Test func aPresenceKeyListedThroughTheMeshResolvesATag() async {
        let rig = rig()
        await rig.mesh.start()
        // Just past a slot edge, so the window's own next edge is 15 minutes off and the limiter's minute comes first.
        let wall = rig.clock.wallMilliseconds()
        rig.clock.advance((BlindTag.slotOf(wallMilliseconds: wall) + 1) * BlindTag.slotMilliseconds - wall + 1)
        let peer = BlindingPeer(bob.nodeId)
        await rig.mesh.listPresenceKeys([bob.nodeId: [peer.key]])
        await rig.mesh.process(.sighted(peer.sighting(peer.tag(wall: rig.clock.wallMilliseconds()))))
        #expect(await rig.mesh.sightings.map(\.nodeId) == [bob.nodeId])
        #expect(await rig.mesh.aliasCounters.resolvedByKey == 1)
        // A second key inside the minute is held; the timer that releases it is aimed at the minute's end.
        let next = BlindingPeer(bob.nodeId, keyByte: 9)
        let due = rig.clock.monotonicMilliseconds() + KeyChurnLimiter.minIntervalMilliseconds
        await rig.mesh.listPresenceKeys([bob.nodeId: [next.key, peer.key]])
        await rig.clock.parked(until: due)
        rig.clock.advance(KeyChurnLimiter.minIntervalMilliseconds)
        var released = false
        for _ in 0..<1000 where !released {
            await Task.yield()
            await rig.mesh.process(.sighted(next.sighting(next.tag(wall: rig.clock.wallMilliseconds()))))
            released = await rig.mesh.aliasCounters.resolvedByKey == 2
        }
        #expect(released, "the held key applied by the timer alone")
    }
}
