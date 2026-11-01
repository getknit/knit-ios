import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The link's proof between two whole nodes, engine and link manager each, as ``Mesh`` drives them (the `link-hello-proof`
/// contract, §5 and §7; knit-ios #25).
@Suite struct LinkPipeProofTests {
    @Test func bothSidesProveAndFramesCross() throws {
        let lab = PipeLab()
        let alice = lab.node(1)
        let bob = lab.node(2)
        let pipe = lab.link(alice, bob)
        #expect(alice.links.neighbors.map(\.nodeId) == [bob.nodeId])
        #expect(bob.links.neighbors.map(\.nodeId) == [alice.nodeId])
        #expect([alice, bob].map(\.links.linksProven) == [1, 1])
        #expect([alice, bob].map { $0.links.linkProofFailed + $0.links.linkClaimRefused } == [0, 0])
        let aliceChannel = try #require(pipe.channel(of: alice))
        let bobChannel = try #require(pipe.channel(of: bob))
        #expect(alice.radio.records(on: aliceChannel).prefix(2).map(\.tag) == [.hello, .proof], "the dialer's HELLO, then its PROOF")
        #expect(bob.radio.records(on: bobChannel).prefix(2).map(\.tag) == [.hello, .proof], "the reply and its PROOF")
        // Each side's link-up push crossed once the link was the peer's.
        #expect(pipe.frames.contains { $0.from == alice.nodeId && $0.type == .profile })
        #expect(pipe.frames.contains { $0.from == bob.nodeId && $0.type == .profile })
    }

    /// A manager shaped like a build from before the proof links unproven, and is never written a PROOF. Its signed profile
    /// still carries the bit here, as this build's engine signs it, so the far end closes the link once that profile lands
    /// (R4); a real v2.10.1 profile carries none, and its link stays.
    @Test func aLegacyManagerLinksUnprovenAndIsNeverWrittenAProof() throws {
        let lab = PipeLab()
        let old = lab.node(1)
        let new = lab.node(2)
        old.links.impostor = LinkManager.Impostor(legacy: true)
        let pipe = lab.link(old, new)
        let oldChannel = try #require(pipe.channel(of: old))
        let newChannel = try #require(pipe.channel(of: new))
        #expect(old.radio.linkUps.map(\.node) == [new.nodeId] && new.radio.linkUps.map(\.node) == [old.nodeId], "both registered")
        #expect(!new.radio.records(on: newChannel).contains { $0.tag == .proof }, "no PROOF to a HELLO without the bit")
        #expect(!old.radio.records(on: oldChannel).contains { $0.tag == .proof })
        let hello = try #require(old.radio.records(on: oldChannel).first)
        #expect(hello.payload == Array("\(old.nodeId)|1|215f".utf8), "no bit and no nonce")
        #expect([old, new].map { $0.links.linksProven + $0.links.linkProofFailed } == [0, 0])
        #expect(new.links.linkClaimRefused == 1, "closed once the profile with the bit landed")
    }

    /// A proof under an id a squatter held yields `.down` then `.up` for that id, so the engine runs the real peer's link-up
    /// afresh: our digest and our profile reach it, none of which the squatter could take for it.
    @Test func aDisplacedSquattersPeerGetsItsOwnLinkUp() throws {
        let lab = PipeLab()
        let target = lab.node(1)
        let real = lab.node(2)
        let squatter = ChannelID(900)
        target.apply(target.links.handle(.accepted(squatter)))
        let claim = Hello(nodeId: real.nodeId.string, capabilities: 0x215F).payload
        target.receive(LinkRecord(.hello, payload: claim).encoded ?? [], on: squatter)
        #expect(target.links.neighbors.map(\.nodeId) == [real.nodeId])
        #expect(target.radio.records(on: squatter).contains { $0.tag == .digest }, "the squatter took the link-up digest")
        let pipe = lab.link(real, target)
        #expect(target.radio.closed == [squatter])
        #expect(target.links.linkClaimRefused == 1 && target.links.linksProven == 1)
        let channel = try #require(pipe.channel(of: target))
        #expect(target.radio.records(on: channel).contains { $0.tag == .digest }, "the real peer gets its own digest")
        #expect(pipe.frames.contains { $0.from == target.nodeId && $0.to == real.nodeId && $0.type == .profile })
        #expect(target.links.neighbors.map(\.nodeId) == [real.nodeId])
    }
}
