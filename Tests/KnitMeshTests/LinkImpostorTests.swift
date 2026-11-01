import KnitCrypto
import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// knit-peer's impostor puts on the wire what it says (``LinkManager/Impostor``), for the `link-hello-proof` trial's T4
/// and T5.
@Suite struct LinkImpostorTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high

    @Test func aLegacyClaimNamesTheIdWithNoBitNoNonceAndNoProof() {
        let rig = LinkRig(local: high)
        rig.links.impostor = LinkManager.Impostor(legacy: true, claimedId: middle)
        let (_, events) = rig.acceptProving(low, on: ChannelID(100))
        #expect(events == [.up(Neighbor(nodeId: low, protocolVersion: 1, capabilities: Capabilities.local.union(.blobHave)))])
        let records = rig.radio.records(on: ChannelID(100))
        #expect(records.map(\.tag) == [.hello], "no PROOF, and none asked of the dialer")
        #expect(records[0].payload == Array("\(middle)|1|215f".utf8))
        #expect(rig.links.linksProven == 0)
    }

    @Test func aLegacyImpostorRefusesNoClaimAndClosesNoLink() {
        let rig = LinkRig(local: high)
        rig.links.impostor = LinkManager.Impostor(legacy: true)
        rig.proofProfiles.ids.insert(low)
        #expect(!rig.accept(low, on: ChannelID(100)).isEmpty)
        rig.links.peerProvesItself(low)
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
        #expect(rig.links.linkClaimRefused == 0)
    }

    @Test func aSignedClaimProvesOurOwnKeyNotTheIdItNames() {
        let rig = LinkRig(local: high)
        rig.links.impostor = LinkManager.Impostor(claimedId: middle)
        let (hello, _) = rig.acceptProving(low, on: ChannelID(100))
        let records = rig.radio.records(on: ChannelID(100))
        #expect(records.map(\.tag) == [.hello, .proof])
        let reply = Hello(payload: records[0].payload)
        #expect(reply.nodeId == middle.string && reply.capabilities.contains(.linkProof) && reply.nonce != nil)
        let proof = records[1].payload
        #expect(
            LinkProof.verify(proof, claimedId: middle, signer: .responder, dialerHello: hello, responderHello: records[0].payload)
                == .failed(.idMismatch), "a target fails it")
        #expect(
            LinkProof.verify(proof, claimedId: high, signer: .responder, dialerHello: hello, responderHello: records[0].payload)
                == .proven(LinkRig.keys(of: high).bundle), "signed with our own key over the bytes that crossed")
    }

    @Test func theNamedPeerIsDialedWhateverTheOrder() {
        // Low waits for high, which finds it: only the impostor's switch has it dial up.
        let plain = LinkRig(local: low)
        plain.sightToPromotion(high)
        #expect(plain.radio.dials.isEmpty)
        let rig = LinkRig(local: low)
        rig.links.impostor = LinkManager.Impostor(legacy: true, claimedId: middle, dials: high)
        rig.sightToPromotion(high)
        #expect(rig.radio.dials.count == 1)
    }
}
