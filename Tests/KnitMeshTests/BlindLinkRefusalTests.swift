import KnitWire
import Testing

@testable import KnitMesh

/// A tag dial that proves an id this node refuses (knit-peer's and the harness's `deny-link`; ``LinkManager/refuse(_:)``):
/// an iPhone against a scripted blinding Android whose tags no key resolves, so nothing names the id until a dial proves it.
/// The dial closes before our PROOF, books no backoff, and marks its dial key (``LinkManager/refusedDials``), so the tag at
/// that address costs one dial while the id stays refused (ADR 2026-11.sv5t's amendment of 2026-11-07).
@Suite struct BlindLinkRefusalTests {
    private let low = LinkRig.low

    /// An iPhone refusing `low`, which has heard `peer`'s `tag` through its head start and so dialed it once.
    private func refusingRig(_ peer: BlindingPeer, tag: NodeId, background: Bool = false) -> LinkRig {
        let rig = LinkRig.iPhone(background: background)
        _ = rig.links.refuse(low)
        if background {
            _ = rig.handle(.sighted(peer.sighting(tag)))
        } else {
            rig.hear(peer.sighting(tag), for: 24_000)
        }
        return rig
    }

    /// As the device ran: every dial still connecting opens and the stranger answers and proves, then its next advert comes
    /// a second on, `seconds` times.
    private func answerEveryDial(_ rig: LinkRig, _ peer: BlindingPeer, tag: NodeId, seconds: Int) throws {
        for _ in 0..<seconds {
            try answerOpenDials(rig, peer, tag: tag)
            _ = rig.advance(1000)
            _ = rig.handle(.sighted(peer.sighting(tag)))
        }
        try answerOpenDials(rig, peer, tag: tag)
    }

    private func answerOpenDials(_ rig: LinkRig, _ peer: BlindingPeer, tag: NodeId) throws {
        for dial in rig.radio.dials where rig.links.channels[dial.channel]?.stage == .connecting {
            _ = rig.handle(.connected(dial.channel))
            _ = try peer.answer(rig, on: dial.channel, told: tag)
        }
    }

    private func refusedLines(_ rig: LinkRig) -> Int {
        rig.log.all.filter { $0.hasPrefix("info link ~zzzz…") && $0.contains(" proved refused \(low) on ") }.count
    }

    /// The lab iPhone on `1d6affd` (2026-11-07): a blinding Pixel 3 refused by id (`deny-link`), its tags unresolved, was
    /// head-start dialed again at every advert, 1 to 3 s apart, 11 to 31 times a tag, with no backoff and no line between.
    /// Each dial opened, proved the refused id, and was closed with nothing booked, so the next advert found the tag
    /// undialed, unheld and unbacked-off. A tag dial that proved a refused id is not dialed again while the id is refused.
    @Test func aTagThatProvedARefusedIdIsNotDialedAgain() throws {
        let peer = BlindingPeer(low)
        let rig = LinkRig.iPhone()
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        _ = rig.links.refuse(low)
        rig.hear(peer.sighting(tag), for: 24_000)
        #expect(rig.radio.dials.count == 1, "the head start ran out: one dial")
        try answerEveryDial(rig, peer, tag: tag, seconds: 30)
        #expect(rig.links.neighbors.isEmpty)
        #expect(rig.radio.dials.count == 1, "redialed a tag that proved a refused id \(rig.radio.dials.count - 1) times in 30 s")
        let channel = try #require(rig.radio.dials.first?.channel)
        #expect(rig.said("link ~zzzz…0 proved refused \(low) on \(channel)"), "the handle, never the tag")
        #expect(!rig.log.all.contains { $0.contains(tag.string) })
        #expect(rig.links.backoffs.isEmpty, "a refusal is our policy, no failure to back off from")
        #expect(rig.links.aliases.counters.claims == 0 && rig.links.heldDials.isEmpty)
    }

    /// The dial closes once the responder's PROOF verifies, before ours: the refused phone sees a dial that ended in its
    /// PROOF wait, and registers nothing.
    @Test func theRefusedDialWritesNoProof() throws {
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: LinkRig.iPhone().clock.wallMilliseconds())
        let refusing = refusingRig(peer, tag: tag)
        try answerOpenDials(refusing, peer, tag: tag)
        let channel = try #require(refusing.radio.dials.first?.channel)
        #expect(refusing.radio.closed.contains(channel))
        #expect(refusing.radio.records(on: channel).map(\.tag) == [.hello], "our HELLO, and no PROOF")
    }

    /// `allow-link`: the next promotion dials the tag at once, held off by no streak the refusal left.
    @Test func permittingTheIdDialsTheTagWithNoWait() throws {
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: LinkRig.iPhone().clock.wallMilliseconds())
        let rig = refusingRig(peer, tag: tag)
        try answerEveryDial(rig, peer, tag: tag, seconds: 3)
        #expect(rig.links.refusedDials.count == 1)
        _ = rig.links.permit(low)
        #expect(rig.links.refusedDials.isEmpty)
        #expect(rig.radio.dials.count == 2, "dialed on permit, with no wait")
        try answerOpenDials(rig, peer, tag: tag)
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
    }

    /// A rotation is a new tag under a new handle: it costs exactly one more dial and one more line.
    @Test func aNewTagFromTheRefusedPhoneCostsOneMoreDial() throws {
        let peer = BlindingPeer(low)
        let rig = LinkRig.iPhone()
        let wall = rig.clock.wallMilliseconds()
        let tag = peer.tag(wall: wall)
        _ = rig.links.refuse(low)
        rig.hear(peer.sighting(tag), for: 24_000)
        try answerEveryDial(rig, peer, tag: tag, seconds: 5)
        let rotated = peer.tag(wall: wall, restart: 1)
        rig.hear(peer.sighting(rotated), for: 24_000)
        try answerEveryDial(rig, peer, tag: rotated, seconds: 30)
        #expect(rig.radio.dials.count == 2)
        #expect(refusedLines(rig) == 2)
    }

    /// A stop forgets the marks with every handle: the start after it costs one dial, and only one.
    @Test func aStopAndStartCostsOneDial() throws {
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: LinkRig.iPhone().clock.wallMilliseconds())
        let rig = refusingRig(peer, tag: tag)
        try answerEveryDial(rig, peer, tag: tag, seconds: 3)
        _ = rig.links.stop()
        #expect(rig.links.refusedDials.isEmpty)
        rig.links.start()
        rig.hear(peer.sighting(tag), for: 24_000)
        try answerEveryDial(rig, peer, tag: tag, seconds: 30)
        #expect(rig.radio.dials.count == 2)
        #expect(refusedLines(rig) == 2)
    }

    /// In the background with no link, seeking dials the refused tag on its first sighting, once.
    @Test func seekingDialsTheRefusedTagOnce() throws {
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: LinkRig.iPhone().clock.wallMilliseconds())
        let rig = refusingRig(peer, tag: tag, background: true)
        #expect(rig.links.isSeeking)
        #expect(rig.radio.dials.count == 1)
        try answerEveryDial(rig, peer, tag: tag, seconds: 30)
        #expect(rig.radio.dials.count == 1)
        #expect(refusedLines(rig) == 1)
    }

    /// `onTagDialed`'s replay mark stands on the refused path (`BluetoothMeshTransport.kt:3889-3899` at `cad69c77b`): a
    /// replayer airing a contact's tag proves its own refused id, the key outranks the proof, and the pair of tag and address
    /// is marked a replay, so the contact airing it from her own address is dialed as herself.
    @Test func aRefusedReplayerIsStillMarkedAReplay() throws {
        let rig = LinkRig.iPhone()
        let contact = BlindingPeer(low)
        let tag = contact.tag(wall: rig.clock.wallMilliseconds())
        rig.links.listPresenceKeys([low: [contact.key]])
        _ = rig.links.refuse(LinkRig.middle)
        var replayer = BlindingPeer(LinkRig.middle, keyByte: 9)
        replayer.address = RadioAddress("addr-replayer")
        rig.hear(replayer.sighting(tag), for: 24_000)
        let dial = try #require(rig.radio.dials.first)
        _ = rig.handle(.connected(dial.channel))
        _ = try replayer.answer(rig, on: dial.channel, told: tag)
        #expect(rig.links.aliasCounters.keyProofMismatches == 1)
        #expect(rig.links.neighbors.isEmpty)
        #expect(rig.links.replayMarks.replayed(tag, at: replayer.address))
        #expect(rig.log.all.contains { $0.hasSuffix(" proved refused \(LinkRig.middle) on \(dial.channel)") })
        rig.hear(contact.sighting(tag), for: 24_000)
        #expect(rig.radio.dials.last?.address == contact.address, "the contact's own address")
    }

    /// A mark is no pin: the cap lets the marked handle go under a flood, its mark with it, and the tag heard again under a
    /// new handle costs one more dial. A quiet tag's mark goes with its presence.
    @Test func aMarkGoesWithItsHandleAndWithItsPresence() throws {
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: LinkRig.iPhone().clock.wallMilliseconds())
        let rig = refusingRig(peer, tag: tag)
        try answerEveryDial(rig, peer, tag: tag, seconds: 1)
        var fixture = BlindFixture()
        let stranger = required(NodeId(bytes: [UInt8](repeating: 9, count: NodeId.byteCount)))
        for index in 0...FormKeys.defaultCap {
            var flooder = peer
            flooder.address = RadioAddress("flood-\(index)")
            _ = rig.handle(.sighted(flooder.sighting(BlindFixture.tag(fixture.key(), owner: stranger, slot: 1))))
        }
        #expect(rig.links.formKeys.existing(tag) == nil, "the marked handle was the eldest")
        #expect(rig.links.refusedDials.isEmpty)

        let quiet = refusingRig(peer, tag: tag)
        try answerEveryDial(quiet, peer, tag: tag, seconds: 1)
        #expect(quiet.links.refusedDials.count == 1)
        _ = quiet.advance(10 * 60_000)
        #expect(quiet.links.refusedDials.isEmpty, "pruned once no sighting names it")
    }
}
