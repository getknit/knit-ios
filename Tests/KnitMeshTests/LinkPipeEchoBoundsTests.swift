import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// What an asker can make us spend, played on both sides with engines and link managers joined by ``LinkPipe``s
/// (knit-ios #20, from knit-next's malicious-fork review, H3 and H2's prefix item): an asker's cut streams leave our own
/// kept prefix alone, and a holder's bound on the serves waiting on one link costs an honest burst nothing it notices.
@Suite struct LinkPipeEchoBoundsTests {
    private let picture: [UInt8] = (0..<200_000).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) }
    private var pictureHash: BlobHash { BlobHash(of: picture) }

    /// A blob of `count` bytes made from `seed`.
    private func blob(_ seed: Int, count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: ($0 &+ seed &* 7919) &* 40_503 >> 7) }
    }

    /// A DM from `sender` to `node` naming `hash`, so `node` wants it from its next re-arm.
    private func wants(_ node: PipeNode, _ hash: BlobHash, from sender: PipeNode, tag: String) {
        node.stores.conversations.accept(sender.nodeId.string)
        node.stores.messages.save(
            MessageRecord(
                id: frameIdOf("dm-\(tag)"),
                senderId: sender.nodeId,
                recipientId: node.nodeId,
                conversationId: sender.nodeId.string,
                body: "",
                sentAt: EngineFixture.start,
                attachment: MessageAttachment(hash: hash)
            ))
    }

    /// Alice keeps a prefix of a picture of her own from a cut link. Carol then has her fetch eight blobs, and each of
    /// their streams is cut past the store's floor. Android would keep all eight and evict hers, the eldest; here they
    /// are echoes, so none is kept, and her picture resumes from her prefix when its holder is back.
    @Test func anAskersCutStreamsLeaveOurKeptPrefixToResumeFrom() {
        let lab = PipeLab()
        let alice = lab.node(1)
        let bob = lab.node(2)
        let carol = lab.node(3)
        bob.hold(picture)
        wants(alice, pictureHash, from: bob, tag: "picture")
        let toBob = lab.link(alice, bob, cutAfter: 50_000)
        #expect(lab.run { !toBob.isUp })
        let kept = alice.partials.length(pictureHash)
        #expect(kept >= 50_000)

        let blobs = (0..<8).map { blob($0, count: 40_000) }
        let hashes = blobs.map { BlobHash(of: $0) }
        for (index, hash) in hashes.enumerated() {
            wants(carol, hash, from: bob, tag: "carol-\(index)")
        }
        lab.link(carol, alice)
        #expect(lab.run { hashes.allSatisfy { alice.engine.blobExchange.isEcho($0) } }, "carol asked alice to pull each through")

        for (index, bytes) in blobs.enumerated() {
            let holder = lab.node(10 + index)
            holder.hold(bytes)
            let pipe = lab.link(alice, holder, cutAfter: 20_000)
            #expect(lab.run { !pipe.isUp }, "holder \(index)'s stream was cut")
        }
        #expect(hashes.allSatisfy { alice.partials.length($0) == 0 }, "an asker's cut streams keep nothing")
        #expect(alice.partials.length(pictureHash) == kept, "and leave ours as it was")

        lab.clock.advance(BlobExchange.serveMemoMilliseconds)
        lab.link(alice, bob)
        #expect(lab.run { alice.stores.blobs.contains(pictureHash) })
        #expect(alice.stores.blobs.bytes(of: pictureHash) == picture)
        #expect(alice.links.filesResumedIn == 1)
        #expect(lab.serves(of: pictureHash).last?.offset == kept, "only the tail crossed")
    }

    /// A newcomer that lacks a dozen blobs its holder has asks for all of them at once. The holder queues eight behind the
    /// one it streams, turns the rest away, and the newcomer has every one inside a cycle all the same.
    @Test func anHonestBurstPastTheServeBoundStillLandsInsideOneCycle() {
        let lab = PipeLab()
        let alice = lab.node(1)
        let bob = lab.node(2)
        let blobs = (0..<12).map { blob($0, count: 4000) }
        for (index, bytes) in blobs.enumerated() {
            bob.hold(bytes)
            wants(alice, BlobHash(of: bytes), from: bob, tag: "burst-\(index)")
        }
        let start = lab.clock.monotonicMilliseconds()
        lab.link(alice, bob)
        #expect(lab.run { blobs.allSatisfy { alice.stores.blobs.contains(BlobHash(of: $0)) } })
        #expect(lab.clock.monotonicMilliseconds() - start < BlobExchange.cycleMilliseconds)
        #expect(bob.engine.blobCounts.servesRefused > 0, "the bound was reached")
        #expect(alice.engine.blobCounts.echoesDeclined == 0)
    }
}
