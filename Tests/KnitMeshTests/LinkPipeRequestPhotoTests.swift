import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Both sides of a message request's photo over link pipes (knit-ios #21): Bob's engine sends Alice a DM with a photo, and
/// Alice's, which has never accepted Bob, asks nothing and takes nothing until she accepts; then she fetches it once, from
/// Bob, and it opens with her row's key.
@Suite struct LinkPipeRequestPhotoTests {
    @Test func aRequestsPhotoCrossesOnlyOnceAcceptedAndThenOnce() throws {
        let lab = PipeLab()
        let alice = lab.node(1)
        let bob = lab.node(2)
        let pipe = lab.link(alice, bob)
        #expect(lab.run { alice.stores.peers.peer(bob.nodeId) != nil && bob.stores.peers.peer(alice.nodeId) != nil })
        let picture: [UInt8] = (0..<200_000).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 11) }
        let sent = try #require(
            bob.engine.sendDirectMessage("", to: alice.nodeId, photo: OutgoingPhoto(bytes: picture, mime: "image/jpeg")))
        let hash = try #require(sent.attachment?.hash)
        #expect(lab.run { alice.stores.messages.message(sent.id) != nil })
        // Two re-offers' worth: nothing asked, nothing served.
        lab.run(limit: 150_000) { false }
        #expect(lab.asks(for: hash).isEmpty && lab.serves(of: hash).isEmpty)
        #expect(!alice.stores.blobs.contains(hash))

        alice.engine.accept(bob.nodeId.string)
        #expect(lab.run { alice.stores.blobs.contains(hash) })
        #expect(lab.serves(of: hash).count == 1 && pipe.serves.count { $0.hash == hash } == 1, "one copy, on the one link")
        let row = try #require(alice.stores.messages.message(sent.id)?.attachment)
        let key = try #require(row.key.flatMap { Base64.decode($0) })
        #expect(AttachmentCrypto.open(try #require(alice.stores.blobs.bytes(of: hash)), key: key) == picture)
    }
}
