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
        #expect(events == [.up(Neighbor(nodeId: low, protocolVersion: 1, capabilities: LinkRig.provingCapabilities))])
        let records = rig.radio.records(on: ChannelID(100))
        #expect(records.map(\.tag) == [.hello], "no PROOF, and none asked of the dialer")
        #expect(records[0].payload == Array("\(middle)|1|215f".utf8))
        #expect(rig.links.linksProven == 0)
    }

    /// The legacy pose (the `link-seal` contract, §7 and T6, revision 3): a legacy impostor claiming another phone's id
    /// airs no `FLAG_LINK_SEAL`, writes a v2.10.x-shaped HELLO, and never opens the sealed form, dialing or answering.
    @Test func theLegacyPoseAirsNoFlagAndNeverSeals() throws {
        let rig = LinkRig(local: high)
        rig.links.impostor = LinkManager.Impostor(legacy: true, claimedId: middle)
        _ = rig.handle(.listening(psm: 0x81))
        #expect(try #require(rig.radio.advertised.last).flags & AdvertPayload.linkSealFlag == 0, "no flag")
        // Dialing an advert that carries the flag still opens plain, claiming the other id with no bit and no nonce.
        rig.sightToPromotion(low, flags: AdvertPayload.dialsGattPeersFlag | AdvertPayload.linkSealFlag)
        let dialed = try #require(rig.radio.dials.last?.channel)
        _ = rig.handle(.connected(dialed))
        let records = rig.radio.records(on: dialed)
        #expect(records.map(\.tag) == [.hello], "a HELLO, never a KEY_SHARE")
        let hello = Hello(payload: records[0].payload)
        #expect(hello.nodeId == middle.string && hello.nonce == nil)
        #expect(!hello.capabilities.contains(.linkProof) && !hello.capabilities.contains(.linkSeal))
        // A KEY_SHARE from a dialer closes the link as an unknown tag does on v2.10.x, answered with nothing.
        let accepted = ChannelID(200)
        _ = rig.handle(.accepted(accepted))
        let share = LinkRecord(.keyShare, payload: LinkSeal.Ephemeral().keyShare).encoded ?? []
        _ = rig.handle(.received(accepted, share))
        #expect(rig.radio.closed.contains(accepted))
        #expect(rig.radio.writes(on: accepted).isEmpty)
        #expect(rig.links.linkSealFailed == 0 && rig.links.linksSealed == 0)
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
            LinkProof.verify(
                proof, claimedId: middle, form: .plain, signer: .responder, dialerHello: hello, responderHello: records[0].payload)
                == .failed(.idMismatch), "a target fails it")
        #expect(
            LinkProof.verify(
                proof, claimedId: high, form: .plain, signer: .responder, dialerHello: hello, responderHello: records[0].payload)
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
