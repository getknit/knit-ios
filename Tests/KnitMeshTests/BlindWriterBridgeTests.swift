import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// What the debug bridge reads and moves of the blinded advert's writer (ADR 2026-11.prsp, "Two gates" and "The bridge and the
/// harness"): the switch at construction apart from the gate, a flip that closes every open channel, the status `advert`
/// reports, and the restarts a forced rotation spends.
@Suite struct BlindWriterBridgeTests {
    let keys = FakeKeys()

    @Test func aSwitchStartedOffAirsTheIdUntilTheBridgeTurnsItOn() throws {
        let rig = LinkRig.blindingIPhone(keys: keys, switchOn: false)
        #expect(rig.aired?.blinded == false)
        #expect(rig.aired?.advertised == LinkRig.high)
        var status = rig.links.advertStatus()
        #expect(status.gate && !status.switchOn && !status.blinding)
        #expect(status.form == .clear)
        #expect(status.install?.cause == "bringUp")
        #expect(status.install?.tag == nil, "a clear install has no tag to source")
        #expect(status.bringUpsInSlot == 0, "only a tag spends a restart")
        rig.links.setBlinding(true)
        let key = try #require(keys.key)
        #expect(rig.airedTag == rig.tag(key, slot: rig.slot))
        status = rig.links.advertStatus()
        #expect(status.switchOn && status.blinding)
        #expect(status.form == .tag)
        #expect(status.install?.cause == "flip")
        #expect(status.install?.tag?.source == "slotted")
        #expect(status.install?.tag?.resolvable == true)
        #expect(status.airedGeneration == key.generation)
        #expect(status.keyGeneration == key.generation)
        #expect(status.epoch == 2)
    }

    @Test func aFlipClosesEveryChannelPastItsDialAndSaysWhy() throws {
        let log = RecordingLog()
        let rig = LinkRig.blindingIPhone(LinkRig.middle, keys: keys, log: log)
        let peer = BlindingPeer(LinkRig.low)
        let live = ChannelID(60)
        _ = try peer.dial(rig, on: live, told: peer.tag(wall: rig.wall))
        let greeting = ChannelID(61)
        _ = rig.handle(.accepted(greeting))
        // A clear Android above us: a blinding iPhone dials it, and the dial is still opening.
        rig.sightToPromotion(LinkRig.high)
        let opening = try #require(rig.radio.dials.last).channel
        rig.links.setBlinding(false)
        #expect(rig.radio.closed.contains(live))
        #expect(rig.radio.closed.contains(greeting))
        #expect(!rig.radio.closed.contains(opening), "a dial still opening writes its HELLO under the new form")
        #expect(rig.said("link \(live) closed: the advert flipped to the id"))
        #expect(rig.said("link \(greeting) closed: the advert flipped to the id"))
        #expect(rig.links.nextDeadline == rig.clock.monotonicMilliseconds(), "the down waits for the next entry")
        #expect(rig.links.advance().contains(.down(LinkRig.low)))
        #expect(rig.links.neighbors.isEmpty)
        #expect(rig.aired?.blinded == false)
    }

    @Test func aFlipToTheFormOnTheAirClosesNothing() throws {
        let rig = LinkRig.blindingIPhone(LinkRig.middle, keys: keys)
        let peer = BlindingPeer(LinkRig.low)
        _ = try peer.dial(rig, on: ChannelID(62), told: peer.tag(wall: rig.wall))
        rig.links.setBlinding(true)
        #expect(rig.radio.closed.isEmpty)
        // A flip while the radio is down closes nothing either: the radio took every channel with it.
        _ = rig.handle(.state(.off))
        let closed = rig.radio.closed.count
        rig.links.setBlinding(false)
        #expect(rig.radio.closed.count == closed)
    }

    @Test func theStatusNamesEveryPeerAndLinkAndNeverATag() throws {
        let rig = LinkRig.blindingIPhone(LinkRig.middle, keys: keys)
        let tag = try #require(rig.airedTag)
        let peer = BlindingPeer(LinkRig.low)
        let told = peer.tag(wall: rig.wall)
        _ = try peer.dial(rig, on: ChannelID(63), told: told)
        // A stranger's tag, which nobody resolves, and a clear Android's id.
        let stranger = BlindingPeer(NodeId(bytes: [UInt8](repeating: 0x5A, count: 16)) ?? LinkRig.high, keyByte: 9)
        let strangerTag = stranger.tag(wall: rig.wall)
        _ = rig.handle(.sighted(stranger.sighting(strangerTag)))
        _ = rig.handle(.sighted(LinkRig.sighting(LinkRig.high)))
        let status = rig.links.advertStatus()
        let link = try #require(status.links.first)
        #expect(link == AdvertStatus.Link(nodeId: LinkRig.low.string, proven: true, dialedByMe: false, tagAware: true, knownBy: .tag))
        let handle = try #require(status.peers.first { !$0.resolved })
        #expect(handle.peer.hasPrefix("~zzzz…"), "an unresolved tag is shown by its handle")
        #expect(handle.blinded)
        #expect(handle.linkedAs == nil)
        #expect(handle.iDial == AdvertOrder.iDial(.init(advertised: tag, blinded: true), .init(advertised: strangerTag, blinded: true)))
        let android = try #require(status.peers.first { $0.peer == LinkRig.high.string })
        #expect(android.resolved && !android.blinded && android.iDial, "a blinding iPhone dials a clear advert")
        let printed = String(describing: status)
        for secret in [tag, told, strangerTag] {
            #expect(!printed.contains(secret.string))
            let hex = secret.bytes.map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined()
            #expect(!printed.contains(hex))
        }
        #expect(status.psm == LinkRig.psm)
        #expect(status.counters == rig.links.writerCounters)
        #expect(status.nextEdgeAt == rig.edge)
        #expect(!status.announced)
    }

    @Test func aLinkWeDialedSaysSoAndALinkedSightingNamesItsLink() throws {
        let rig = LinkRig.blindingIPhone(LinkRig.middle, keys: keys)
        rig.sightToPromotion(LinkRig.high)
        let dial = try #require(rig.radio.dials.last)
        _ = rig.handle(.connected(dial.channel))
        _ = try rig.answerProving(LinkRig.high, on: dial.channel)
        let status = rig.links.advertStatus()
        let link = try #require(status.links.first)
        #expect(link.dialedByMe)
        #expect(status.peers.first { $0.peer == LinkRig.high.string }?.linkedAs == LinkRig.high.string)
    }

    @Test func eachForcedRotationAndBringUpSpendsARestartUntilTheSlotAirsRandomTags() {
        let rig = LinkRig.blindingIPhone(keys: keys)
        #expect(rig.links.advertStatus().restartsLeft == BlindTag.restarts - 1, "the bring-up spent the first")
        #expect(rig.links.advertStatus().bringUpsInSlot == 1)
        // A second bring-up in the slot, after Bluetooth went off and on.
        _ = rig.handle(.state(.off))
        _ = rig.handle(.state(.on))
        _ = rig.handle(.listening(psm: LinkRig.psm))
        #expect(rig.links.advertStatus().bringUpsInSlot == 2)
        // Past the edge before the turn ran: the mark is the last slot's, so this one has every restart.
        rig.clock.advance(rig.edge + 1000 - rig.wall)
        #expect(rig.links.advertStatus().restartsLeft == BlindTag.restarts)
        // A fresh slot, well clear of its edge.
        rig.run(untilWall: rig.wall)
        var status = rig.links.advertStatus()
        #expect(status.restartsLeft == BlindTag.restarts - 1)
        #expect(status.bringUpsInSlot == 0, "the bring-ups were the last slot's")
        for left in (0..<BlindTag.restarts - 1).reversed() {
            rig.clock.advance(LinkManager.forcedRotationGraceMilliseconds)
            #expect(rig.links.forceRotation().rotated)
            status = rig.links.advertStatus()
            #expect(status.restartsLeft == left)
            #expect(status.install?.cause == "forced")
            #expect(status.install?.tag?.resolvable == true)
        }
        rig.clock.advance(LinkManager.forcedRotationGraceMilliseconds)
        #expect(rig.links.forceRotation().rotated)
        status = rig.links.advertStatus()
        #expect(status.restartsLeft == 0)
        #expect(status.install?.tag?.resolvable == false, "past the restarts, a random tag no contact resolves")
        #expect(status.install?.tag?.source == "slotted", "the schedule's own fallback, under the key held")
    }

    @Test func anAnnouncementLeavesTheSlotOnTheAirNoRestarts() {
        let rig = LinkRig.blindingIPhone(keys: keys)
        rig.run(untilWall: rig.edge - AdvertRotation.leadMilliseconds)
        let status = rig.links.advertStatus()
        #expect(status.announced)
        #expect(status.restartsLeft == 0, "the mark moved to the coming slot")
    }

    @Test func aMarkThatWouldNotWriteLeavesEveryRestart() {
        keys.marks.answer = .refused
        let rig = LinkRig.blindingIPhone(keys: keys)
        let status = rig.links.advertStatus()
        #expect(status.install?.tag?.source == "markFailed")
        #expect(status.restartsLeft == BlindTag.restarts, "the store holds no mark, so nothing was spent")
    }

    @Test func noKeyReportsNoRestartsAndNoGeneration() {
        let rig = LinkRig.blindingIPhone(keys: FakeKeys(nil))
        let status = rig.links.advertStatus()
        #expect(status.keyGeneration == nil)
        #expect(status.restartsLeft == nil)
        #expect(status.install?.tag?.source == "noKey")
    }

    @Test func aBuildThatMayNotBlindReportsItsGateShut() {
        let rig = LinkRig.iPhone(LinkRig.middle)
        var status = rig.links.advertStatus()
        #expect(!status.gate && status.switchOn && !status.blinding)
        #expect(status.form == nil, "nothing installed before the listener")
        #expect(!status.radioUp)
        _ = rig.handle(.listening(psm: LinkRig.psm))
        status = rig.links.advertStatus()
        #expect(status.form == .clear && status.radioUp && !status.pending)
        #expect(rig.links.forceRotation().refused == .clear)
    }
}
