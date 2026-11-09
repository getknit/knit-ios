import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// A tag dial and the seal (the `link-seal` contract, §2 and §7): the blinded advert dialed decides the form as a clear one
/// does, and a plain tag dial between two sealing builds is refused in `answeredTag`.
@Suite struct LinkSealTagDialTests {
    private let low = LinkRig.low

    /// A blinding sealing phone's reply HELLO: the seal's bit with the proof's, a nonce, and its `t`.
    private static func sealingReply(_ peer: NodeId, told: NodeId) -> [UInt8] {
        let caps = Capabilities.local.union(.blobHave)
        let fields = ["\(peer)", "1", caps.hex, "n\(Hex.encode(LinkProof.freshNonce()))", "t\(Hex.encode(told.bytes))"]
        return Array(fields.joined(separator: "|").utf8)
    }

    @Test func aTagDialToASealingAdvertOpensSealedProvesSealedAndCountsIt() throws {
        let rig = LinkRig.iPhone()
        let peer = BlindingPeer(low, flags: LinkRig.sealingFlags)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        rig.hear(peer.sighting(tag), for: 24_000)
        let dial = try #require(rig.radio.dials.last)
        _ = rig.handle(.connected(dial.channel))
        let far = SealedFarEnd(role: .responder)
        try far.take(from: rig, on: dial.channel)
        #expect(far.outer == [.keyShare], "the tag dial opens with our KEY_SHARE")
        _ = rig.handle(.received(dial.channel, far.keyShare))
        let ours = try #require(try far.take(from: rig, on: dial.channel).first)
        #expect(ours.tag == .hello)
        #expect(Hello(payload: ours.payload).addressed == tag.bytes, "a = the tag dialed, inside the seal")
        let reply = Self.sealingReply(low, told: tag)
        let proof = try far.proof(low, dialerHello: ours.payload, responderHello: reply)
        let events = rig.handle(.received(dial.channel, try far.seal(LinkRecord.bytes(.hello, reply), proof)))
        #expect(events.contains { if case .up(let neighbor) = $0 { neighbor.nodeId == low } else { false } })
        #expect(rig.said("link ~zzzz…0 proved \(low) on \(dial.channel)"))
        let dialerProof = try #require(try far.take(from: rig, on: dial.channel).first { $0.tag == .proof })
        let shares = try #require(far.shares)
        let verified = LinkProof.verify(
            dialerProof.payload,
            claimedId: rig.links.localId,
            form: .sealed(shares),
            signer: .dialer,
            dialerHello: ours.payload,
            responderHello: reply
        )
        #expect(verified == .proven(LinkRig.keys(of: rig.links.localId).bundle))
        #expect(far.outer.dropFirst().allSatisfy { $0 == .sealed })
        #expect([rig.links.linksSealed, rig.links.linksProven, rig.links.linkSealFailed] == [1, 1, 0])
    }

    @Test func aPlainTagDialAnsweredByASealingBuildIsRefusedWithNoProof() throws {
        let rig = LinkRig.iPhone()
        let peer = BlindingPeer(low) // no FLAG_LINK_SEAL: a stripped or stale flag makes the tag dial plain
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        rig.hear(peer.sighting(tag), for: 24_000)
        let dial = try #require(rig.radio.dials.last)
        _ = rig.handle(.connected(dial.channel))
        let ours = Hello(payload: try #require(rig.ourHelloPayload(on: dial.channel)))
        #expect(ours.capabilities.contains(.linkSeal), "our HELLO carries the bit")
        let reply = Self.sealingReply(low, told: tag)
        let proof = try LinkRig.proofRecord(
            LinkRig.keys(of: low), as: .responder, dialerHello: ours.payload, responderHello: reply)
        _ = rig.handle(.received(dial.channel, LinkRecord.bytes(.hello, reply) + proof))
        #expect(rig.radio.records(on: dial.channel).map(\.tag) == [.hello], "no PROOF of ours")
        #expect(rig.radio.closed.contains(dial.channel))
        #expect(rig.links.neighbors.isEmpty)
        #expect(rig.links.linkSealRefused == 1)
        #expect(rig.links.linkProofFailed == 0, "refused before the proof's checks")
        #expect(rig.said("link refused \(low): a plain link between two sealing builds"))
        let handle = try #require(rig.links.formKeys.existing(tag))
        #expect(rig.links.backoffs[.tag(handle, peer.address)] != nil, "the dialer backs off")
    }
}
