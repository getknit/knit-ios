import KnitMesh
import KnitWire
import Testing

/// The responder's rule, the records behind a HELLO, and writing (`BluetoothMeshTransport.superviseAccepted` and
/// `FramedLink`, with companion change A1's rule).
@Suite struct LinkAdmissionTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high

    // MARK: The responder's rule

    @Test func anUnsightedDialerIsAdmittedWhateverTheOrder() {
        // An iPhone we cannot see: A1's rule, which this port keeps from day one.
        let rig = LinkRig(local: high)
        let events = rig.accept(low, on: ChannelID(100))
        #expect(events == [.up(Neighbor(nodeId: low, protocolVersion: 1, capabilities: 0xFFF))])
        #expect(rig.radio.records(on: ChannelID(100)) == [LinkRig.ourHello(high)])
    }

    @Test func aSightedLargerDialerIsAdmitted() {
        let rig = LinkRig(local: low)
        _ = rig.handle(.sighted(LinkRig.sighting(high, rssi: -60)))
        #expect(rig.accept(high, on: ChannelID(100)).count == 1)
    }

    @Test func aSightedDialerWeShouldDialIsRefusedWithoutAReply() {
        // The cross-dial breaker: we dial the smaller id, so its dial to us is refused.
        let rig = LinkRig(local: high)
        _ = rig.handle(.sighted(LinkRig.sighting(low, rssi: -60)))
        let events = rig.accept(low, on: ChannelID(100))
        #expect(events.isEmpty)
        #expect(rig.radio.records(on: ChannelID(100)).isEmpty)
        #expect(rig.radio.closed == [ChannelID(100)])
    }

    @Test func aDialerClaimingOurIdOrNoneIsRefused() {
        let rig = LinkRig(local: high)
        #expect(rig.accept(high, on: ChannelID(100)).isEmpty)
        _ = rig.handle(.accepted(ChannelID(101)))
        let garbage = LinkRecord(.hello, payload: Array("not-an-id|1|fff".utf8)).encoded ?? []
        #expect(rig.handle(.received(ChannelID(101), garbage)).isEmpty)
        #expect(rig.radio.closed == [ChannelID(100), ChannelID(101)])
    }

    // MARK: Telling the radio who spoke (the payload lifetime's rule 2)

    @Test func everyHelloReadIsReportedToTheRadioWhateverTheVerdict() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        // Sighted and below us: refused, but it still said who it is at that address.
        _ = rig.handle(.sighted(LinkRig.sighting(middle, rssi: -60)))
        _ = rig.accept(middle, on: ChannelID(101))
        #expect(rig.radio.closed == [ChannelID(101)])
        #expect(
            rig.radio.hellos == [
                FakeRadio.HeardHello(node: low, channel: ChannelID(100)), FakeRadio.HeardHello(node: middle, channel: ChannelID(101)),
            ])
    }

    @Test func aReplyNamingAnotherNodeIsReportedAndARefusalIsNot() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low, flags: 0)
        let first = try #require(rig.radio.dials.last?.channel)
        _ = rig.handle(.connected(first))
        // The address's new node replies: the dial fails, and the radio hears who answered.
        _ = rig.handle(.received(first, LinkRig.helloRecord(middle)))
        #expect(rig.radio.closed == [first])
        #expect(rig.radio.hellos == [FakeRadio.HeardHello(node: middle, channel: first)])
        // A responder that closes without a reply says nothing.
        _ = rig.handle(.accepted(ChannelID(200)))
        _ = rig.handle(.closed(ChannelID(200)))
        let garbage = LinkRecord(.hello, payload: Array("not-an-id|1|fff".utf8)).encoded ?? []
        _ = rig.handle(.accepted(ChannelID(201)))
        _ = rig.handle(.received(ChannelID(201), garbage))
        #expect(rig.radio.hellos.count == 1)
    }

    @Test func aFirstRecordThatIsNotAHelloIsRefused() {
        let rig = LinkRig(local: high)
        _ = rig.handle(.accepted(ChannelID(100)))
        let events = rig.handle(.received(ChannelID(100), LinkRig.frameRecord(LinkRig.signedFrame("early"))))
        #expect(events.isEmpty)
        #expect(rig.radio.closed == [ChannelID(100)])
    }

    @Test func aDialerThatNeverSaysHelloIsClosedAfterFiveSeconds() {
        let rig = LinkRig(local: high)
        _ = rig.handle(.accepted(ChannelID(100)))
        _ = rig.advance(4999)
        #expect(rig.radio.closed.isEmpty)
        _ = rig.advance(1)
        #expect(rig.radio.closed == [ChannelID(100)])
    }

    @Test func aSightedLinkedPeerDialingAgainIsRefused() {
        let rig = LinkRig(local: low)
        _ = rig.handle(.sighted(LinkRig.sighting(high, rssi: -60)))
        _ = rig.accept(high, on: ChannelID(100))
        let events = rig.accept(high, on: ChannelID(101))
        #expect(events.isEmpty)
        #expect(rig.radio.closed == [ChannelID(101)])
        #expect(rig.links.neighbors.count == 1)
    }

    @Test func anUnsightedLinkedPeerDialingAgainReplacesItsStaleLink() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        _ = rig.advance(30_000)
        let events = rig.accept(low, on: ChannelID(101))
        #expect(events == [.down(low), .up(Neighbor(nodeId: low, protocolVersion: 1, capabilities: 0xFFF))])
        #expect(rig.radio.closed == [ChannelID(100)])
        // The stale channel's close arriving now must not take the new link down (Android's bug at :787).
        #expect(rig.handle(.closed(ChannelID(100))).isEmpty)
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
    }

    @Test func aLinkYoungerThanThirtySecondsIsNeverReplaced() {
        // A1's floor: the HELLO is unauthenticated, so a device claiming the peer's id can cut its link at most
        // this often.
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        _ = rig.advance(29_999)
        #expect(rig.accept(low, on: ChannelID(101)).isEmpty)
        #expect(rig.radio.closed == [ChannelID(101)])
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
    }

    @Test func aDialLandingOnAnExistingLinkIsClosedAndTheOldOneKept() throws {
        let rig = LinkRig(local: low, advertisesServiceData: false)
        rig.sightToPromotion(high, flags: 0)
        let dial = try #require(rig.radio.dials.first?.channel)
        // Meanwhile the peer, now advertising the GATT flag, dials us and is admitted.
        rig.clock.advance(1)
        _ = rig.handle(.sighted(LinkRig.sighting(high)))
        _ = rig.accept(high, on: ChannelID(100))
        _ = rig.handle(.connected(dial))
        let events = rig.handle(.received(dial, LinkRig.helloRecord(high)))
        #expect(events.isEmpty)
        #expect(rig.radio.closed.contains(dial))
        #expect(rig.links.neighbors.map(\.nodeId) == [high])
    }

    // MARK: Records

    @Test func recordsBehindTheHelloAreFramesAndDigests() throws {
        let rig = LinkRig(local: high)
        _ = rig.handle(.accepted(ChannelID(100)))
        let frame = LinkRig.signedFrame("m1")
        let digest = LinkRecord(.digest, payload: LinkJSON.digestPayload(ids: ["a", "b"])).encoded ?? []
        let bytes = LinkRig.helloRecord(low) + LinkRig.frameRecord(frame) + digest
        // Split mid-record: a radio chunks however it likes.
        let first = rig.handle(.received(ChannelID(100), Array(bytes.prefix(40))))
        let rest = rig.handle(.received(ChannelID(100), Array(bytes.dropFirst(40))))
        let envelope = try RelayEnvelope(decoding: frame.signed)
        #expect(first == [.up(Neighbor(nodeId: low, protocolVersion: 1, capabilities: 0xFFF))])
        #expect(rest == [.frame(InboundFrame(wire: frame, envelope: envelope, from: low)), .digest(["a", "b"], from: low)])
    }

    @Test func fileRecordsAndKeepalivesAreDiscardedAndAnUndecodableFrameIsSkipped() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        let file = [LinkRecord(.fileHeader, payload: Array("{}".utf8)), LinkRecord(.fileChunk, payload: [1, 2, 3]), LinkRecord(.fileEnd)]
        let noise = file + [LinkRecord(.keepalive), LinkRecord(.frame, payload: [0xFF]), LinkRecord(.hello, payload: [])]
        let events = rig.handle(.received(ChannelID(100), noise.compactMap(\.encoded).flatMap(\.self)))
        #expect(events.isEmpty)
        #expect(rig.links.undecodableFrames == 1)
        #expect(rig.links.discardedFileRecords == 3)
        #expect(rig.links.neighbors.count == 1, "the link stays up")
    }

    @Test func anUnknownRecordTagDropsTheLinkAsAndroidDoes() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        let events = rig.handle(.received(ChannelID(100), [9, 0, 0, 0, 0]))
        #expect(events == [.down(low)])
        #expect(rig.radio.closed == [ChannelID(100)])
    }

    @Test func bytesBeforeADialOpensEndIt() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.received(id, LinkRig.helloRecord(low)))
        #expect(rig.radio.closed == [id])
    }

    // MARK: Writing

    @Test func aFrameIsWrittenToEveryLinkOnceAndNeverBackWhereItCameFrom() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        _ = rig.accept(middle, on: ChannelID(101))
        let incoming = LinkRig.signedFrame("in", sig: 5)
        _ = rig.handle(.received(ChannelID(100), LinkRig.frameRecord(incoming)))
        rig.links.send(incoming.relayed(), to: nil)
        #expect(rig.radio.frames(on: ChannelID(100)).isEmpty, "the link it came in on already has it")
        #expect(rig.radio.frames(on: ChannelID(101)) == [incoming.relayed()])
        rig.links.send(incoming.relayed(), to: middle)
        #expect(rig.radio.frames(on: ChannelID(101)).count == 1, "one write per link per frame")
    }

    @Test func anUnsignedFrameIsAlwaysWritten() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        let unsigned = WireEnvelope(relay: false, sig: [], signed: LinkRig.signedFrame("u").signed)
        rig.links.send(unsigned, to: low)
        rig.links.send(unsigned, to: low)
        #expect(rig.radio.frames(on: ChannelID(100)).count == 2)
    }

    @Test func writesAreSlicedToEightKilobytes() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        let big = RelayEnvelope(type: .chat, id: "big", senderId: low.string, payload: Array(repeating: 1, count: 20_000))
        rig.links.send(WireEnvelope(sig: [7], signed: big.encoded), to: low)
        let sizes = rig.radio.writeSizes(on: ChannelID(100)).dropFirst()
        #expect(sizes.allSatisfy { $0 <= 8192 })
        #expect(sizes.count == 3)
        #expect(rig.radio.frames(on: ChannelID(100)).count == 1, "reassembled, it is one record")
    }

    @Test func aFrameTooLargeForARecordIsDropped() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        let payload = Array(repeating: UInt8(0), count: LinkRecord.maxPayloadBytes)
        let huge = RelayEnvelope(type: .chat, id: "huge", senderId: low.string, payload: payload)
        rig.links.send(WireEnvelope(sig: [7], signed: huge.encoded), to: nil)
        #expect(rig.radio.frames(on: ChannelID(100)).isEmpty)
    }

    @Test func aDigestIsWrittenAsJSONToALinkedPeerOnly() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        rig.links.sendDigest(["m1", "m2"], to: low)
        rig.links.sendDigest(["m3"], to: middle)
        let digests = rig.radio.records(on: ChannelID(100)).filter { $0.tag == .digest }
        #expect(digests.map(\.payload) == [Array(#"{"ids":["m1","m2"]}"#.utf8)])
    }

    @Test func aDigestReachesTheRadioWholeSoItCanReplaceOneStillWaiting() {
        // Cut into writes, a digest could not be found in the radio's queue again (knit-next ADR 2026-09.tjfb).
        let rig = LinkRig(local: high, configuration: LinkManager.Configuration(maxWriteBytes: 64))
        _ = rig.accept(low, on: ChannelID(100))
        let hello = rig.radio.writeSizes(on: ChannelID(100)).count
        let ids = (0..<20).map { "frame-\($0)" }
        rig.links.sendDigest(ids, to: low)
        let sizes = rig.radio.writeSizes(on: ChannelID(100)).dropFirst(hello)
        #expect(sizes.count == 1)
        #expect(sizes.first ?? 0 > 64)
        #expect(rig.radio.records(on: ChannelID(100)).last?.tag == .digest)
    }

    @Test func aFrameForAnUnlinkedPeerGoesNowhere() {
        let rig = LinkRig(local: high)
        rig.links.send(LinkRig.signedFrame("lost"), to: low)
        #expect(rig.radio.frames(on: ChannelID(100)).isEmpty)
    }
}
