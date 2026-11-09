import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Two whole nodes on a sealed link (the `link-seal` contract, §4 and §5), the pipe reading inside the seal: a photo's FILE
/// records span frames and are reported written as they cross, and a digest past one frame's plaintext replaced while it
/// waited still opens in order. Nothing fails a seal either way.
@Suite struct LinkPipeSealTests {
    private func noFailedSeal(_ nodes: PipeNode..., sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(nodes.map(\.links.linkSealFailed) == nodes.map { _ in 0 }, sourceLocation: sourceLocation)
    }

    @Test func aPhotoOfManyChunksCrossesASealedLinkWhole() throws {
        let lab = PipeLab(sealed: true)
        let alice = lab.node(1)
        let bob = lab.node(2)
        let pipe = lab.link(alice, bob)
        #expect([alice, bob].map(\.links.linksSealed) == [1, 1])
        #expect(lab.run { alice.stores.peers.peer(bob.nodeId) != nil && bob.stores.peers.peer(alice.nodeId) != nil })
        alice.engine.accept(bob.nodeId.string)
        let picture: [UInt8] = (0..<200_000).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 11) }
        let sent = try #require(
            bob.engine.sendDirectMessage("", to: alice.nodeId, photo: OutgoingPhoto(bytes: picture, mime: "image/jpeg")))
        let hash = try #require(sent.attachment?.hash)
        #expect(lab.run { alice.stores.blobs.contains(hash) })
        #expect(pipe.serves.count { $0.hash == hash } == 1, "one copy")
        #expect(pipe.chunkBytes >= picture.count, "every chunk crossed inside frames, each reported written")
        let row = try #require(alice.stores.messages.message(sent.id)?.attachment)
        let key = try #require(row.key.flatMap { Base64.decode($0) })
        #expect(AttachmentCrypto.open(try #require(alice.stores.blobs.bytes(of: hash)), key: key) == picture)
        noFailedSeal(alice, bob)
    }

    @Test func aDigestPastOneFrameReplacedBehindABacklogOpensInOrder() throws {
        let lab = PipeLab(sealed: true)
        let alice = lab.node(1)
        let bob = lab.node(2)
        let pipe = lab.link(alice, bob)
        #expect(lab.run(limit: 5000) { alice.stores.peers.peer(bob.nodeId) != nil && bob.stores.peers.peer(alice.nodeId) != nil })
        let channel = try #require(pipe.channel(of: alice))
        let before = pipe.digests.count
        alice.radio.hold(channel)
        alice.links.send(LinkRig.signedFrame("backlog"), to: bob.nodeId)
        let older = (0..<400).map { "older-\($0)-" + String(repeating: "x", count: 24) }
        let newer = (0..<500).map { "newer-\($0)-" + String(repeating: "y", count: 24) }
        alice.links.sendDigest(older, to: bob.nodeId)
        alice.links.sendDigest(newer, to: bob.nodeId)
        #expect((LinkRecord(.digest, payload: LinkJSON.digestPayload(ids: newer)).encoded?.count ?? 0) > 8171, "past one frame")
        alice.radio.release(channel)
        lab.pump()
        let crossed = pipe.digests.dropFirst(before).filter { $0.from == alice.nodeId }
        #expect(crossed.map(\.ids) == [newer.count], "the newer digest alone, in the older one's place")
        #expect(pipe.isLinked)
        noFailedSeal(alice, bob)
    }
}
