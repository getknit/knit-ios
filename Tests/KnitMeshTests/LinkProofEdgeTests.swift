import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The link proof's edges (the `link-hello-proof` contract, §5 and §7; knit-ios #25): a key that will not sign, a reply
/// that claims the bit with no nonce, a bad record where the PROOF belongs, and the stored profile's answer.
@Suite struct LinkProofEdgeTests {
    private let low = LinkRig.low
    private let high = LinkRig.high

    private func counts(_ rig: LinkRig) -> [Int] {
        [rig.links.linksProven, rig.links.linkProofFailed, rig.links.linkClaimRefused]
    }

    /// A responder whose key will not sign fails the proof before its one write, so the dialer reads nothing.
    @Test func aResponderWhoseKeyWillNotSignWritesNothing() {
        let rig = LinkRig(local: high)
        rig.links.signProof = { _, _, _ in nil }
        let id = ChannelID(100)
        #expect(rig.acceptProving(low, on: id).events.isEmpty)
        #expect(rig.radio.records(on: id).isEmpty, "no reply and no PROOF")
        #expect(rig.radio.closed == [id])
        #expect(counts(rig) == [0, 1, 0])
        #expect(rig.said("link \(id) proof failed for \(low): unsigned"))
    }

    /// A dialer whose key will not sign checks the responder's PROOF, writes none of its own, and backs off.
    @Test func aDialerWhoseKeyWillNotSignWritesNoProofAndBacksOff() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.connected(id))
        rig.links.signProof = { _, _, _ in nil }
        let (_, events) = try rig.answerProving(low, on: id)
        #expect(events.isEmpty, "nothing registers")
        #expect(rig.radio.records(on: id).map(\.tag) == [.hello], "our HELLO, and no PROOF")
        #expect(rig.radio.closed == [id])
        #expect(counts(rig) == [0, 1, 0])
        #expect(rig.links.backoffs[.peer(.node(low))] != nil)
        #expect(rig.said("link \(id) proof failed for \(low): unsigned"))
    }

    /// A reply whose caps claim the bit with no valid nonce fails the dialer's proof, and the dialer backs off.
    @Test func aReplyClaimingTheBitWithoutANonceFailsTheDialersProof() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let id = try #require(rig.radio.dials.first?.channel)
        _ = rig.handle(.connected(id))
        let reply = try #require(LinkRecord(.hello, payload: Array("\(low)|1|4215f".utf8)).encoded)
        #expect(rig.handle(.received(id, reply)).isEmpty)
        #expect(rig.radio.closed == [id])
        #expect(counts(rig) == [0, 1, 0])
        #expect(rig.links.backoffs[.peer(.node(low))] != nil)
        #expect(rig.said("link \(id) proof failed for \(low): nonce"))
    }

    /// A record that does not parse where the dialer's PROOF belongs fails the proof as well as the link.
    @Test func aBadRecordWhereTheProofBelongsFailsIt() {
        let rig = LinkRig(local: high)
        let id = ChannelID(100)
        _ = rig.acceptProving(low, on: id)
        #expect(rig.handle(.received(id, [0x57, 0x36, 0x00, 0x01, 0x02])).isEmpty)
        #expect(rig.radio.closed == [id])
        #expect(counts(rig) == [0, 1, 0])
        #expect(rig.said("link \(id) proof failed for \(low): record"))
    }

    /// What the mesh asks the peer store: whether the stored profile's capabilities carry the bit.
    @Test func theStoredProfileSaysWhetherAnIdProvesItself() {
        let stores = MeshStores.inMemory()
        let carries = Mesh.profileCarriesProof(in: stores.peers)
        let ids = [fixtureNodeId(41), fixtureNodeId(42), fixtureNodeId(43)]
        for (id, capabilities) in zip(ids, [Int64(0x4015F), 0x15F, nil]) {
            stores.peers.upsert(PeerRecord(nodeId: id, name: "", status: "", publicKey: "", capabilities: capabilities, updatedAt: 1))
        }
        #expect(carries(ids[0]))
        #expect(!carries(ids[1]), "a profile without the bit")
        #expect(!carries(ids[2]), "a profile with no capabilities")
        #expect(!carries(fixtureNodeId(44)), "no profile")
    }
}
