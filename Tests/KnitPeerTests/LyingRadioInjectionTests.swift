import Foundation
import KnitCrypto
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// `--lying`'s radio injects the padded profile and the one-shot ask only between records, never ahead of our HELLO, once
/// per ready channel and only to the peer named, on its own and under a real link manager (`door-cap-lying-peers`).
@Suite(.timeLimit(.minutes(1))) struct LyingRadioInjectionTests: LyingRadioFixture {
    @Test func theForgeFollowsOurHelloOnALinkWeDialedAndOneWeAccepted() throws {
        for dials in [true, false] {
            let inner = CallRadio()
            let radio = lying(inner)
            radio.setPaddedProfile(forge())
            if dials {
                radio.write(hello(local), to: channel)
                #expect(inner.records(on: channel).count == 1, "nothing before the peer's HELLO")
                radio.heardHello(from: peer, told: nil, announced: nil, on: channel)
                #expect(inner.records(on: channel).count == 1, "nothing between the HELLOs and the link's registration")
                radio.linkUp(peer, on: channel)
            } else {
                radio.heardHello(from: peer, told: nil, announced: nil, on: channel)
                radio.linkUp(peer, on: channel)
                #expect(inner.records(on: channel).isEmpty, "nothing before our HELLO")
                radio.write(hello(local), to: channel)
            }
            let records = inner.records(on: channel)
            #expect(records.map(\.tag) == [.hello, .frame], "dials \(dials)")
            #expect(try WireEnvelope(decoding: records[1].payload) == forge().wire)
            #expect(inner.calls.last == .ring(channel))
            #expect(radio.counts.forgedProfilesWritten == [peer: 1])
        }
    }

    @Test func theForgeGoesOncePerReadyChannelBetweenRecordsAndAgainOnANewOne() throws {
        let inner = CallRadio()
        let radio = lying(inner)
        dialed(radio, channel, peer: peer)
        let big = slices(record(.frame, answer(extra: 250).encoded))
        radio.write(big[0], to: channel)
        #expect(radio.setPaddedProfile(forge()) == 0, "partway through a record: it waits")
        for slice in big.dropFirst() {
            radio.write(slice, to: channel)
        }
        radio.write(record(.frame, answer().encoded), to: channel)
        var records = inner.records(on: channel)
        #expect(records.map(\.tag) == [.hello, .frame, .frame, .frame])
        #expect(try WireEnvelope(decoding: records[2].payload) == forge().wire, "after the sliced record, whole")
        #expect(records[1].payload == answer(extra: 250).encoded)

        let second = ChannelID(6)
        accepted(radio, second, peer: other)
        #expect(inner.records(on: second).map(\.tag) == [.hello, .frame])
        #expect(radio.counts.forgedProfilesWritten == [peer: 1, other: 1])

        #expect(radio.setPaddedProfile(forge("forged-again")) == 2, "a new forge reaches every ready channel")
        radio.setPaddedProfile(nil)
        let third = ChannelID(7)
        dialed(radio, third, peer: peer)
        #expect(inner.records(on: third).map(\.tag) == [.hello], "cleared: no more")
        records = inner.records(on: channel)
        #expect(records.count == 5)
        #expect(radio.counts.forgedProfilesWritten == [peer: 2, other: 2])
    }

    @Test func anAskGoesOnlyToTheNamedPeersReadyChannel() throws {
        let inner = CallRadio()
        let radio = lying(inner)
        let toPeer = ChannelID(10)
        let toOther = ChannelID(11)
        let notReady = ChannelID(12)
        dialed(radio, toPeer, peer: peer)
        accepted(radio, toOther, peer: other)
        radio.linkUp(peer, on: notReady)
        #expect(radio.askBlob(photo, of: fixtureNodeId(9)) == nil)
        let id = try #require(radio.askBlob(photo, of: peer))
        let records = inner.records(on: toPeer)
        #expect(records.map(\.tag) == [.hello, .frame])
        #expect(inner.records(on: toOther).map(\.tag) == [.hello])
        #expect(inner.records(on: notReady).isEmpty)
        let wire = try WireEnvelope(decoding: records[1].payload)
        let envelope = try RelayEnvelope(decoding: wire.signed)
        #expect(!wire.relay && wire.sig.isEmpty && wire.ttl == WireEnvelope.defaultTTL && wire.hops == 0)
        #expect(envelope.type == .blobRequest && envelope.id == id && envelope.senderId == local.string && envelope.sentAt == 0)
        #expect(FrameId.admits(envelope))
        #expect(try BlobRequestContent(decoding: envelope.payload) == BlobRequestContent(hash: photo.string, pull: LyingRadio.plainAskPull))
        #expect(LyingRadio.plainAskPull == BlobExchange.pullBudget, "a plain ask carries what a want of our own mints")
        #expect(inner.calls.last == .ring(toPeer))
        #expect(radio.counts.blobAsksSent == [peer: 1])
    }

    @Test func anAskPartwayThroughARecordWaitsForItsEnd() throws {
        let inner = CallRadio()
        let radio = lying(inner)
        dialed(radio, channel, peer: peer)
        let big = slices(record(.frame, answer(extra: 250).encoded))
        radio.write(big[0], to: channel)
        #expect(radio.askBlob(photo, of: peer) != nil, "taken")
        #expect(radio.counts.blobAsksSent.isEmpty, "not written yet")
        for slice in big.dropFirst() {
            radio.write(slice, to: channel)
        }
        let records = inner.records(on: channel)
        #expect(records.count == 3 && records[1].payload == answer(extra: 250).encoded)
        #expect(try RelayEnvelope(decoding: WireEnvelope(decoding: records[2].payload).signed).type == .blobRequest)
        #expect(radio.counts.blobAsksSent == [peer: 1])
    }

    // MARK: Through a link manager

    @Test func aRealLinkManagerWritesItsHelloBeforeTheForgeOnALinkItDialedAndOneItAccepted() throws {
        let keys = [identity(1), identity(2)].sorted { $0.nodeId < $1.nodeId }
        // The larger id dials (`LinkManager.weDial`).
        let (us, them) = (keys[1].nodeId, keys[0].nodeId)
        for dials in [true, false] {
            let inner = CallRadio(dialing: ChannelID(40))
            let radio = LyingRadio(wrapping: inner, localId: us, profile: nil, random: CountingGenerator())
            radio.setPaddedProfile(forge())
            let clock = HandClock()
            let links = LinkManager(identity: keys[1], radio: radio, clock: clock, random: CountingGenerator())
            links.start()
            let id: ChannelID
            if dials {
                let advert = AdvertPayload(capabilities: 0xFFF, nodeId: them, digestCue: 0, psm: 0x80, flags: 0)
                for step in 0...7 {
                    clock.advance(step == 0 ? 0 : 2000)
                    _ = links.handle(.sighted(RadioSighting(address: RadioAddress("far"), advert: advert, rssi: -50)))
                }
                id = try #require(inner.dialed)
                _ = links.handle(.connected(id))
                #expect(inner.records(on: id).map(\.tag) == [.hello])
            } else {
                id = ChannelID(41)
                _ = links.handle(.accepted(id))
            }
            _ = links.handle(.received(id, record(.hello, Hello(nodeId: them.string, capabilities: 0x215F).payload)))
            #expect(links.neighbors.map(\.nodeId) == [them], "dials \(dials)")
            let records = inner.records(on: id)
            #expect(records.first?.tag == .hello)
            #expect(records.first.map { Hello(payload: $0.payload).nodeId } == us.string, "our HELLO first")
            #expect(records.dropFirst().first.flatMap { try? WireEnvelope(decoding: $0.payload) } == forge().wire, "the forge next")
        }
    }

    /// `--lying` over `--flood`, under a real link manager, on a link that proves itself: nothing is written between our
    /// reply and the dialer's PROOF, the reply and our PROOF pass through in the one write they came in, and the flood and
    /// the forge start once the link registered (``Radio/linkUp(_:on:)``).
    @Test func neitherTheFloodNorTheForgeWritesBetweenAHelloAndAProof() throws {
        let keys = [identity(1), identity(2)].sorted { $0.nodeId < $1.nodeId }
        let (us, them) = (keys[1], keys[0])
        let inner = PeerRadio()
        let flood = FloodRadio(wrapping: inner, bytesPerSecond: 10_000)
        let radio = LyingRadio(wrapping: flood, localId: us.nodeId, profile: nil, random: CountingGenerator())
        radio.setPaddedProfile(forge())
        let links = LinkManager(identity: us, radio: radio, clock: HandClock(), random: CountingGenerator())
        links.start()
        let id = ChannelID(41)
        _ = links.handle(.accepted(id))
        let proving = Capabilities.local.union(.blobHave).subtracting(.linkSeal)
        let hello = Hello(nodeId: them.nodeId.string, capabilities: proving, nonce: LinkProof.freshNonce())
        _ = links.handle(.received(id, record(.hello, hello.payload)))
        flood.tick(milliseconds: 1000)
        #expect(inner.records(on: id).map(\.tag) == [.hello, .proof], "nothing behind our PROOF before the dialer's")
        #expect(flood.floodedBytes == 0)
        let reply = try #require(inner.records(on: id).first?.payload)
        let proof = try LinkProof.payload(keys: them, form: .plain, signer: .dialer, dialerHello: hello.payload, responderHello: reply)
        _ = links.handle(.received(id, record(.proof, proof)))
        #expect(links.neighbors.map(\.nodeId) == [them.nodeId])
        flood.tick(milliseconds: 1000)
        let records = inner.records(on: id)
        #expect(records.count > 3)
        #expect(records.prefix(3).map(\.tag) == [.hello, .proof, .frame])
        #expect(try WireEnvelope(decoding: records[2].payload) == forge().wire, "the forge first, once the link is up")
        #expect(flood.floodedBytes > 0, "then the flood")
    }
}
