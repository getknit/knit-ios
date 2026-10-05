import KnitMesh
import KnitWire
import Testing

/// When the link manager rings a peer's doorbell: iOS wakes a suspended iPhone for a write to it, and not for data on
/// the link, so every frame that goes out needs a ring soon after, and a burst of them needs few.
struct LinkDoorbellTests {
    private let interval: Int64 = 5000

    @Test func aFrameRingsTheLinkItWentOut() throws {
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        #expect(rig.radio.rings.isEmpty)
        rig.links.send(LinkRig.signedFrame("f1"), to: LinkRig.low)
        #expect(rig.radio.rings == [id])
        #expect(rig.links.rings == 1)
    }

    @Test func aBurstRingsAtItsStartAndOnceAfterItsEnd() throws {
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        rig.links.send(LinkRig.signedFrame("f1"), to: nil)
        rig.clock.advance(1000)
        rig.links.send(LinkRig.signedFrame("f2", sig: 2), to: nil)
        rig.clock.advance(1000)
        rig.links.send(LinkRig.signedFrame("f3", sig: 3), to: nil)
        #expect(rig.radio.rings == [id])
        #expect(rig.links.nextDeadline == rig.clock.monotonicMilliseconds() - 2000 + interval)
        _ = rig.advance(2999)
        #expect(rig.radio.rings == [id])
        _ = rig.advance(1)
        #expect(rig.radio.rings == [id, id])
        _ = rig.advance(60_000)
        #expect(rig.radio.rings == [id, id])
    }

    @Test func aFrameAfterTheIntervalRingsAtOnce() throws {
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        rig.links.send(LinkRig.signedFrame("f1"), to: nil)
        rig.clock.advance(interval)
        rig.links.send(LinkRig.signedFrame("f2", sig: 2), to: nil)
        #expect(rig.radio.rings == [id, id])
    }

    /// Android never rings for a file (`BluetoothMeshTransport.sendFile`), and neither does this port, so a photo
    /// streaming to a locked iPhone wakes it no more often than its frames do (ADR 2026-09.khjj, ADR 2026-10.nh55).
    @Test func fileRecordsDoNotRing() throws {
        let rig = LinkRig(local: LinkRig.high)
        _ = try rig.link(LinkRig.low)
        let file: [UInt8] = Array(repeating: 7, count: 40 * 1024)
        let hash = try #require(BlobHash(String(repeating: "a", count: 64)))
        let outbound = OutboundFile(kind: .avatar, hash: hash, mime: "image/jpeg", size: file.count) { offset, count in
            Array(file[offset..<min(file.count, offset + count)])
        }
        #expect(rig.links.sendFile(outbound, to: LinkRig.low))
        // One chunk a deadline, as the timer would fire them.
        for _ in 0..<20 {
            _ = rig.advance(600)
        }
        #expect(rig.links.filesSent == 1)
        #expect(rig.radio.rings.isEmpty)
    }

    @Test func digestsDoNotRing() throws {
        let rig = LinkRig(local: LinkRig.high)
        _ = try rig.link(LinkRig.low)
        rig.links.sendDigest(["a", "b"], to: LinkRig.low)
        _ = rig.advance(interval)
        #expect(rig.radio.rings.isEmpty)
    }

    @Test func aFrameTheLinkAlreadyCarriedDoesNotRing() throws {
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        let frame = LinkRig.signedFrame("f1")
        _ = rig.handle(.received(id, LinkRig.frameRecord(frame)))
        rig.links.send(frame, to: nil)
        #expect(rig.radio.rings.isEmpty)
    }

    @Test func eachLinkRingsOnItsOwnSchedule() throws {
        let rig = LinkRig(local: LinkRig.high)
        let low = try rig.link(LinkRig.low)
        let middle = try rig.link(LinkRig.middle)
        rig.links.send(LinkRig.signedFrame("f1"), to: LinkRig.low)
        rig.clock.advance(1000)
        rig.links.send(LinkRig.signedFrame("f2", sig: 2), to: nil)
        #expect(rig.radio.rings == [low, middle])
        _ = rig.advance(interval - 1000)
        #expect(rig.radio.rings == [low, middle, low])
    }

    @Test func ringsDueTogetherGoOutInChannelOrder() throws {
        let rig = LinkRig(local: LinkRig.high)
        let low = try rig.link(LinkRig.low)
        let middle = try rig.link(LinkRig.middle)
        rig.links.send(LinkRig.signedFrame("f1"), to: nil)
        rig.clock.advance(1000)
        rig.links.send(LinkRig.signedFrame("f2", sig: 2), to: nil)
        _ = rig.advance(interval - 1000)
        #expect(rig.radio.rings == [low, middle, low, middle])
    }

    @Test func aLinkThatClosesForgetsItsNextRing() throws {
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        rig.links.send(LinkRig.signedFrame("f1"), to: nil)
        rig.links.send(LinkRig.signedFrame("f2", sig: 2), to: nil)
        _ = rig.handle(.closed(id))
        #expect(rig.links.nextDeadline == nil || rig.links.nextDeadline != rig.clock.monotonicMilliseconds() + interval)
        _ = rig.advance(interval)
        #expect(rig.radio.rings == [id])
    }

    @Test func ringsHeardAreCounted() {
        let rig = LinkRig(local: LinkRig.high)
        #expect(rig.handle(.rung).isEmpty)
        #expect(rig.handle(.rung).isEmpty)
        #expect(rig.links.ringsHeard == 2)
        #expect(rig.links.rings == 0)
    }

    // MARK: What rings

    @Test(arguments: [FrameType.typing, .blobRequest, .keyRequest])
    func upkeepGoesOutWithoutRinging(type: FrameType) throws {
        // Android skips the same three (`DoorbellPolicy.rings`): the 60 s tick re-sends the requests.
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        rig.links.send(LinkRig.signedFrame("u1", type: type), to: LinkRig.low)
        _ = rig.advance(interval)
        #expect(rig.radio.frames(on: id).count == 1)
        #expect(rig.radio.rings.isEmpty)
        #expect(rig.links.rings == 0)
    }

    @Test func anUnsignedRequestDoesNotRing() throws {
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        let request = RelayEnvelope(type: .blobRequest, id: "b1", senderId: LinkRig.high.string, payload: [])
        rig.links.send(WireEnvelope(ttl: 1, relay: false, sig: [], signed: request.encoded), to: LinkRig.low)
        #expect(rig.radio.frames(on: id).count == 1)
        #expect(rig.radio.rings.isEmpty)
    }

    @Test(arguments: [FrameType.chat, .profile, .receipt, .reaction, FrameType(rawValue: "future")])
    func everyOtherTypeRings(type: FrameType) throws {
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        rig.links.send(LinkRig.signedFrame("f1", type: type), to: LinkRig.low)
        #expect(rig.radio.rings == [id])
    }

    @Test func aFrameWhoseTypeCannotBeReadRings() throws {
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        rig.links.send(WireEnvelope(sig: Array(repeating: 1, count: 64), signed: [0xFF]), to: LinkRig.low)
        #expect(rig.radio.rings == [id])
    }

    @Test func upkeepLeavesTheScheduleAlone() throws {
        let rig = LinkRig(local: LinkRig.high)
        let id = try rig.link(LinkRig.low)
        rig.links.send(LinkRig.signedFrame("k1", type: .keyRequest), to: LinkRig.low)
        rig.clock.advance(1000)
        rig.links.send(LinkRig.signedFrame("f1", sig: 2), to: LinkRig.low)
        #expect(rig.radio.rings == [id], "the chat rings at once: the keyreq before it did not start the interval")
        _ = rig.advance(interval)
        #expect(rig.radio.rings == [id])
    }

    // MARK: Asking to be rung

    @Test(arguments: [false, true])
    func theHelloAsksToBeRungExactlyWhenTheRadioServesADoorbell(serves: Bool) throws {
        let rig = LinkRig(local: LinkRig.high, servesDoorbell: serves)
        rig.sightToPromotion(LinkRig.low)
        let dialed = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.connected(dialed))
        let accepted = ChannelID(100)
        _ = rig.accept(LinkRig.middle, on: accepted)
        for id in [dialed, accepted] {
            let hello = try #require(rig.radio.records(on: id).first)
            #expect(hello == LinkRig.ourHello(LinkRig.high, servesDoorbell: serves))
            #expect(Hello(payload: hello.payload).capabilities.hex == (serves ? "100f" : "f"))
        }
    }

    // MARK: Tuning

    @Test func aZeroIntervalNeverRings() throws {
        let rig = LinkRig(local: LinkRig.high, configuration: LinkManager.Configuration(ringIntervalMilliseconds: 0))
        _ = try rig.link(LinkRig.low)
        rig.links.send(LinkRig.signedFrame("f1"), to: nil)
        _ = rig.advance(interval)
        #expect(rig.radio.rings.isEmpty)
    }
}
