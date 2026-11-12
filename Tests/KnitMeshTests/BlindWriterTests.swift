import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The blinded advert's writer wired into the link manager (ADR 2026-11.prsp): the snapshot, the gate, the bring-up, the
/// slot turn on the wall clock, key changes, flips and forced rotations, on a ``LinkRig`` with a hand-moved clock.
@Suite struct BlindWriterTests {
    let keys = FakeKeys()

    @Test func aBlindingIPhoneAirsItsSlottedTagUnderTheFlagAndNeverItsId() throws {
        let rig = LinkRig.blindingIPhone(keys: keys)
        let payload = try #require(rig.aired)
        let key = try #require(keys.key)
        #expect(payload.blinded)
        #expect(payload.advertised == rig.tag(key, slot: rig.slot))
        #expect(payload.digestCue == 0)
        // The seal's flag rides the blinded form too (`link-seal` §1).
        #expect(payload.flags == AdvertPayload.dialsGattPeersFlag | AdvertPayload.blindedFlag | AdvertPayload.linkSealFlag)
        #expect(payload.psm == LinkRig.psm)
        #expect(keys.marks.marks[1] == PresenceMark(slot: rig.slot, restart: 0), "the mark is durable before the tag airs")
        #expect(rig.links.blinds)
        #expect(rig.links.mine == AdvertOrder.Mine(current: .init(advertised: payload.advertised, blinded: true), previous: nil))
        let counted = rig.links.writerCounters
        #expect(counted.rotationsByBringUp == 1)
        #expect(counted.resolvable == 1)
        #expect(counted.unannounced == 1, "a bring-up is nobody's announcement")
        // A custody change moves no blinded payload: its cue is zero.
        rig.links.updateDigestCue(0xABCD)
        _ = rig.advance(2000)
        #expect(rig.radio.advertised.count == 1)
    }

    @Test func itsHelloTellsTheTagItAirsAndTheFormItDialed() throws {
        let rig = LinkRig.blindingIPhone(LinkRig.middle, keys: keys)
        // A clear Android whose id sorts above ours: a clear iPhone would wait to be dialed, a blinding one dials.
        rig.sightToPromotion(LinkRig.high)
        let dial = try #require(rig.radio.dials.last)
        _ = rig.handle(.connected(dial.channel))
        let hello = Hello(payload: try #require(rig.ourHelloPayload(on: dial.channel)))
        #expect(hello.told == rig.airedTag?.bytes)
        #expect(hello.addressed == LinkRig.high.bytes)
        #expect(hello.capabilities.contains(.blindAdvert))
    }

    @Test func withTheGateOffNothingRuns() throws {
        // A release build: may not blind, keys attached all the same.
        let rig = LinkRig.iPhone(LinkRig.middle)
        rig.links.attachPresenceKeys(keys.source)
        rig.links.ownPresenceKeyChanged(keys.key)
        _ = rig.handle(.listening(psm: LinkRig.psm))
        #expect(rig.aired?.blinded == false)
        #expect(rig.aired?.advertised == LinkRig.middle)
        #expect(!rig.links.blinds)
        rig.links.setBlinding(true)
        #expect(rig.radio.advertised.count == 1, "no switch in a build that may not blind")
        #expect(rig.links.forceRotation().refused == .clear)
        #expect(rig.links.nextDeadline == rig.clock.monotonicMilliseconds(), "only the key change waits, to be taken")
        _ = rig.advance(0)
        #expect(rig.links.nextDeadline == nil, "no turn")
        rig.sightToPromotion(LinkRig.low)
        let dial = try #require(rig.radio.dials.last)
        _ = rig.handle(.connected(dial.channel))
        #expect(Hello(payload: try #require(rig.ourHelloPayload(on: dial.channel))).told == nil, "no `t`")
        #expect(rig.links.writerCounters == LinkManager.WriterCounters())
        #expect(keys.writes == 0, "no mark written")
    }

    @Test func aBuildThatMayBlindButHoldsNoKeySourceAirsItsId() {
        var configuration = LinkManager.Configuration()
        configuration.blindsAdvert = true
        let rig = LinkRig(local: LinkRig.high, advertisesServiceData: false, servesDoorbell: true, configuration: configuration)
        _ = rig.handle(.listening(psm: LinkRig.psm))
        #expect(rig.aired?.blinded == false)
        #expect(!rig.links.blinds)
    }

    @Test func aFlipRotatesToTheWantedFormAndBack() throws {
        let rig = LinkRig.blindingIPhone(keys: keys)
        let first = try #require(rig.airedTag)
        rig.links.setBlinding(true)
        #expect(rig.radio.advertised.count == 1, "no change")
        rig.links.setBlinding(false)
        #expect(rig.aired?.advertised == LinkRig.high)
        #expect(rig.aired?.blinded == false)
        #expect(rig.links.mine.previous == BlindFixture.blinded(first), "the tag before is still mine to a dial made against it")
        #expect(rig.links.nextDeadline == nil, "no turn while clear")
        rig.links.setBlinding(true)
        let key = try #require(keys.key)
        #expect(rig.airedTag == rig.tag(key, slot: rig.slot, restart: 1), "a fresh tag: the next restart in the slot")
        #expect(rig.links.writerCounters.rotationsByFlip == 2)
    }

    @Test func aFlipWhileTheRadioIsDownTakesEffectAtTheNextBringUp() {
        let rig = LinkRig.blindingIPhone(keys: keys)
        _ = rig.handle(.state(.off))
        rig.links.setBlinding(false)
        #expect(rig.links.writerCounters.rotationsByFlip == 0)
        _ = rig.handle(.state(.on))
        _ = rig.handle(.listening(psm: LinkRig.psm))
        #expect(rig.aired?.advertised == LinkRig.high)
        #expect(rig.aired?.blinded == false)
    }

    @Test func aListenerThatOpensWhileStoppedBringsNothingUp() {
        let rig = LinkRig.blindingIPhone(keys: keys, listening: false)
        _ = rig.links.stop()
        _ = rig.handle(.listening(psm: LinkRig.psm))
        #expect(rig.radio.advertised.isEmpty)
        #expect(rig.links.writerCounters.rotationsByBringUp == 0)
    }

    @Test func aNewPSMUnderTheSameFormIsNoRotation() throws {
        let rig = LinkRig.blindingIPhone(keys: keys)
        let tag = try #require(rig.airedTag)
        _ = rig.handle(.listening(psm: 0x93))
        #expect(rig.airedTag == tag)
        #expect(rig.aired?.psm == 0x93)
        #expect(rig.links.writerCounters.rotationsByBringUp == 1)
    }

    @Test func pastFourBringUpsInASlotTheTagIsRandom() throws {
        let rig = LinkRig.blindingIPhone(keys: keys)
        let key = try #require(keys.key)
        var tags = [try #require(rig.airedTag)]
        for _ in 0..<4 {
            _ = rig.links.stop()
            rig.links.start()
            _ = rig.handle(.listening(psm: LinkRig.psm))
            tags.append(try #require(rig.airedTag))
        }
        #expect(Array(tags.prefix(4)) == (0..<4).map { rig.tag(key, slot: rig.slot, restart: $0) })
        #expect(!(0..<4).map { rig.tag(key, slot: rig.slot, restart: $0) }.contains(tags[4]), "the fifth resolves to nobody")
        #expect(AdvertForm.hasTagPrefix(tags[4].bytes))
        #expect(rig.links.writerCounters.rotationsByBringUp == 5)
        #expect(rig.links.writerCounters.randomScheduled == 1)
    }

    @Test func aKeyChangeWaitsForTheAdvanceThenRotatesAtOnce() {
        let rig = LinkRig.blindingIPhone(keys: keys)
        let writes = keys.writes
        let fresh = FakeKeys.key(2, byte: 0x22)
        keys.key = fresh
        rig.links.ownPresenceKeyChanged(fresh)
        #expect(keys.writes == writes, "never a mark write from inside the engine's call, which may sit in a store unit")
        #expect(rig.links.nextDeadline == rig.clock.monotonicMilliseconds())
        _ = rig.advance(0)
        #expect(rig.airedTag == rig.tag(fresh, slot: rig.slot))
        #expect(rig.links.writerCounters.rotationsByKeyChange == 1)
        // The same key again is no change; nil is a fresh restart onto a random tag.
        rig.links.ownPresenceKeyChanged(fresh)
        _ = rig.advance(0)
        #expect(rig.links.writerCounters.rotationsByKeyChange == 1)
        keys.key = nil
        rig.links.ownPresenceKeyChanged(nil)
        _ = rig.advance(0)
        #expect(rig.links.writerCounters.rotationsByKeyChange == 2)
        #expect(rig.links.writerCounters.randomNoKey == 1)
    }

    @Test func theSessionsFirstKeyCompletesABringUpThatHadNone() {
        let none = FakeKeys(nil)
        let rig = LinkRig.blindingIPhone(keys: none)
        #expect(rig.links.writerCounters.randomNoKey == 1)
        let key = FakeKeys.key(3, byte: 0x33)
        none.key = key
        rig.links.ownPresenceKeyChanged(key)
        _ = rig.advance(0)
        #expect(rig.airedTag == rig.tag(key, slot: rig.slot))
        #expect(rig.links.writerCounters.rotationsByBringUp == 2)
    }

    @Test func aKeyTheEngineMovedPastAirsARandomTag() {
        let rig = LinkRig.blindingIPhone(keys: keys)
        keys.key = FakeKeys.key(2, byte: 0x22) // the engine moved on; the link manager has not taken it in
        rig.links.setBlinding(false)
        rig.links.setBlinding(true)
        #expect(rig.links.writerCounters.randomKeyMoved == 1)
        #expect(rig.airedTag.map { AdvertForm.hasTagPrefix($0.bytes) } == true)
    }

    @Test func ourOwnTagHeardBackIsNoPeer() throws {
        let rig = LinkRig.blindingIPhone(keys: keys)
        let own = try #require(rig.sightingOfItsPayload(at: "addr-echo"))
        _ = rig.handle(.sighted(own))
        #expect(rig.links.aliasCounters.tagsHeard == 0)
        #expect(rig.radio.dials.isEmpty)
    }

    @Test func aPayloadThatWouldNameTheIdIsNeverHandedToTheRadio() {
        let rig = LinkRig.blindingIPhone(keys: keys)
        let before = rig.radio.advertised.count
        #expect(rig.links.writerCounters.droppedPayloads == 0)
        // The writer's last check, reached only by a payload built wrong: it is counted and goes nowhere.
        var writer = rig.links.blindWriter.writer
        _ = writer.push { aired in
            AdvertPayload(capabilities: .local, advertised: LinkRig.high, digestCue: 0, psm: aired.psm, flags: AdvertPayload.blindedFlag)
        }
        rig.links.blindWriter.writer = writer
        #expect(rig.links.writerCounters.droppedPayloads == 1)
        #expect(rig.radio.advertised.count == before)
    }
}
