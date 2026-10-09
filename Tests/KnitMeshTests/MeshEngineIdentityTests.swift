import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// A picture keeps the identity it arrived under (ADR 2026-10.f3mv; knit-next ADR 2026-10.mptm, whose `MeshManagerTest`,
/// `InboundPipelineTest` and `AttachmentReuseLabTest` these follow): a pick this phone holds goes out as that blob, a
/// sealed one learns its plaintext's name, and a key-less frame from someone already in the chain is shown from our own
/// copy, while a stranger's is pulled.
@Suite struct MeshEngineIdentityTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)

    private let picture = Array("a picture passed hand to hand".utf8)
    private var plainHash: BlobHash { BlobHash(of: picture) }

    /// Bob's DM to Alice carrying `picture` sealed, delivered and its blob landed: the copy Alice holds.
    private func holdingBobsSealedCopy(_ fixture: EngineFixture) throws -> MessageAttachment {
        fixture.link(bob)
        try fixture.pin(bob)
        let sealed = try #require(AttachmentCrypto.seal(picture))
        let hash = BlobHash(of: sealed.blob)
        let content = MessageContent(
            body: "", attachmentHash: hash.string, attachmentMime: "image/jpeg", attachmentKey: Base64.encode(sealed.key))
        fixture.deliver(try bob.directMessage("", to: alice, id: "dm-1", sentAt: EngineFixture.start, content: content), from: bob)
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: hash, mime: "image/jpeg", bytes: sealed.blob))
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return try #require(fixture.stores.messages.message("dm-1")?.attachment)
    }

    /// A room post from `author` naming `picture` by its plaintext.
    private func roomPost(by author: TestPeer, id: String) throws -> TestFrame {
        let post = ChatContent(body: "", attachmentHash: plainHash.string, attachmentMime: "image/jpeg")
        return try author.signed(
            RelayEnvelope(type: .chat, id: id, senderId: author.nodeId.string, sentAt: EngineFixture.start, payload: post.encoded))
    }

    // MARK: Naming the plaintext

    @Test func aPulledSealedAttachmentLearnsItsPlaintextName() throws {
        let fixture = EngineFixture(alice)
        let held = try holdingBobsSealedCopy(fixture)
        #expect(held.plainHash == plainHash)
        #expect(fixture.stores.messages.keyWantingPlainHash(held.hash) == nil)
    }

    @Test func ourOwnSealedSendKnowsItsPlaintextAndTheBytesPicked() throws {
        let fixture = EngineFixture(alice)
        let original = Array("the camera's own file".utf8)
        let photo = OutgoingPhoto(bytes: picture, mime: "image/jpeg", sourceHash: BlobHash(of: original))
        let sent = try #require(fixture.engine.sendDirectMessage("", to: bob.nodeId, photo: photo)?.attachment)
        #expect(sent.plainHash == plainHash && sent.sourceHash == BlobHash(of: original))
        let posted = try #require(fixture.engine.postToRoom("", photo: photo)?.attachment)
        #expect(posted.plainHash == nil && posted.sourceHash == BlobHash(of: original), "a room post's hash is its plaintext's")
    }

    // MARK: Picking

    @Test func aForwardGoesOutUnderTheIdentityItArrivedUnderAndSealsNothing() throws {
        let fixture = EngineFixture(alice)
        let held = try holdingBobsSealedCopy(fixture)
        let found = try #require(fixture.engine.heldPhoto(picked: picture))
        #expect(found == OutgoingPhoto(bytes: picture, mime: "image/jpeg", identity: PhotoIdentity(hash: held.hash, key: held.key)))
        let blobs = fixture.stores.blobs.allHashes()
        try fixture.pin(carol)
        let forward = try #require(fixture.engine.sendDirectMessage("", to: carol.nodeId, photo: found)?.attachment)
        #expect(forward.hash == held.hash && forward.key == held.key && forward.plainHash == plainHash)
        #expect(fixture.stores.blobs.allHashes() == blobs, "nothing sealed again")
    }

    @Test func aRoomPictureForwardedToADmKeepsItsPublicKeylessName() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        fixture.deliver(try roomPost(by: bob, id: "post-1"), from: bob)
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: plainHash, mime: "image/jpeg", bytes: picture))
        fixture.transport.clear()
        let found = try #require(fixture.engine.heldPhoto(picked: picture))
        #expect(found.identity == PhotoIdentity(hash: plainHash, key: nil))
        let forward = try #require(fixture.engine.sendDirectMessage("", to: bob.nodeId, photo: found))
        #expect(forward.attachment == MessageAttachment(hash: plainHash, mime: "image/jpeg"))
        let sent = try #require(fixture.transport.written(.chat).first)
        let enc = try #require(try ChatContent(decoding: sent.envelope.payload).enc)
        let header = MessageCrypto.header(
            id: sent.envelope.id, senderId: alice.nodeId.string, sentAt: sent.envelope.sentAt, thread: bob.nodeId.string)
        let content = try #require(MessageCrypto.open(enc, header: header, as: bob.keys))
        #expect(content.attachmentHash == plainHash.string && content.attachmentKey == nil)
    }

    @Test func theRoomsPublicNameWinsOverASealedCopyWeHold() throws {
        let fixture = EngineFixture(alice)
        _ = try holdingBobsSealedCopy(fixture)
        fixture.deliver(try roomPost(by: bob, id: "post-1"), from: bob)
        #expect(fixture.stores.blobs.contains(plainHash), "copied from the sealed one")
        #expect(fixture.engine.heldPhoto(picked: picture)?.identity == PhotoIdentity(hash: plainHash, key: nil))
    }

    @Test func anIdentityWhoseBlobWentBeforeTheSendIsSealedFresh() throws {
        let fixture = EngineFixture(alice)
        let gone = PhotoIdentity(hash: BlobHash(of: Array("long gone".utf8)), key: "aw==")
        let photo = OutgoingPhoto(bytes: picture, mime: "image/jpeg", identity: gone)
        let sent = try #require(fixture.engine.sendDirectMessage("", to: bob.nodeId, photo: photo)?.attachment)
        #expect(sent.hash != gone.hash && sent.key != nil && sent.plainHash == plainHash)
        let key = try #require(sent.key.flatMap { Base64.decode($0) })
        #expect(fixture.stores.blobs.bytes(of: sent.hash).flatMap { AttachmentCrypto.open($0, key: key) } == picture)
    }

    @Test func theOriginalOfAPhotoWeSentFindsTheIdentityItWentOutUnder() throws {
        let fixture = EngineFixture(alice)
        let original = Array("the camera's own file, metadata and all".utf8)
        let photo = OutgoingPhoto(bytes: picture, mime: "image/webp", sourceHash: BlobHash(of: original))
        let sent = try #require(fixture.engine.sendDirectMessage("", to: bob.nodeId, photo: photo)?.attachment)
        let found = try #require(fixture.engine.heldPhoto(picked: original))
        #expect(found.bytes == picture, "opened out of the sealed blob")
        #expect(found.mime == "image/webp" && found.identity == PhotoIdentity(hash: sent.hash, key: sent.key))
        #expect(found.sourceHash == BlobHash(of: original), "remembered again by the next send")
    }

    @Test func aPictureThePhoneDoesNotHoldIsNoIdentity() {
        let fixture = EngineFixture(alice)
        #expect(fixture.engine.heldPhoto(picked: picture) == nil)
        // A row whose blob will not open to the plaintext it names is skipped, as is one whose blob is gone.
        let original = Array("picked again".utf8)
        let blob = Array("not a sealed blob at all, just bytes".utf8)
        fixture.stores.blobs.insert(blob, hash: BlobHash(of: blob), mime: "image/jpeg", storedAt: 1)
        let broken = MessageAttachment(
            hash: BlobHash(of: blob), mime: "image/jpeg", key: "aw==", plainHash: plainHash, sourceHash: BlobHash(of: original))
        fixture.stores.messages.save(
            MessageRecord(
                id: "m1",
                senderId: alice.nodeId,
                recipientId: bob.nodeId,
                conversationId: bob.nodeId.string,
                body: "",
                sentAt: 1,
                attachment: broken
            )
        )
        #expect(fixture.engine.heldPhoto(picked: original) == nil)
        fixture.stores.blobs.remove(BlobHash(of: blob))
        #expect(fixture.engine.heldPhoto(picked: picture) == nil)
    }

    // MARK: Copying from our own store

    @Test func aKeylessForwardFromTheDmPeerWeGotItFromIsShownWithNothingPulled() throws {
        let fixture = EngineFixture(alice)
        _ = try holdingBobsSealedCopy(fixture)
        let forward = MessageContent(body: "again", attachmentHash: plainHash.string, attachmentMime: "image/jpeg")
        fixture.deliver(try bob.directMessage("again", to: alice, id: "dm-2", sentAt: EngineFixture.start, content: forward), from: bob)
        #expect(fixture.stores.blobs.bytes(of: plainHash) == picture)
        #expect(fixture.transport.written(.blobRequest).isEmpty && !fixture.engine.blobExchange.isWanted(plainHash))
        #expect(fixture.engine.drainEvents().contains(.attachmentArrived(plainHash)))
    }

    @Test func theDmPeerWeSentItToMayHaveItShownFromOurCopy() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        try fixture.pin(carol)
        _ = try #require(fixture.engine.sendDirectMessage("", to: carol.nodeId, photo: OutgoingPhoto(bytes: picture, mime: "image/jpeg")))
        fixture.transport.clear()
        fixture.deliver(try roomPost(by: carol, id: "post-1"), from: carol)
        #expect(fixture.stores.blobs.bytes(of: plainHash) == picture)
        #expect(fixture.transport.written(.blobRequest).isEmpty)
    }

    @Test func aMemberOfTheGroupItCameThroughMayHaveItShownFromOurCopy() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        try fixture.pin(carol)
        let info = roster([bob, carol, alice], createdBy: bob)
        let sealed = try #require(AttachmentCrypto.seal(picture))
        let hash = BlobHash(of: sealed.blob)
        let content = MessageContent(
            body: "", attachmentHash: hash.string, attachmentMime: "image/jpeg", attachmentKey: Base64.encode(sealed.key))
        fixture.deliver(
            try bob.groupMessage("", in: info, to: [alice, carol], id: "gm-1", sentAt: EngineFixture.start, content: content), from: bob)
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: hash, mime: "image/jpeg", bytes: sealed.blob))
        fixture.transport.clear()
        fixture.deliver(try roomPost(by: carol, id: "post-1"), from: carol)
        #expect(fixture.stores.blobs.bytes(of: plainHash) == picture, "Carol was in the group it came through")
        #expect(fixture.transport.written(.blobRequest).isEmpty)
    }

    /// The oracle a copy would open: anyone holding the file could post it and see which phones answer unasked.
    @Test func aStrangerPostingTheFileLearnsNothingFromUs() throws {
        let fixture = EngineFixture(alice)
        _ = try holdingBobsSealedCopy(fixture)
        fixture.link(dave)
        try fixture.pin(dave)
        fixture.transport.clear()
        fixture.deliver(try roomPost(by: dave, id: "post-1"), from: dave)
        #expect(!fixture.stores.blobs.contains(plainHash), "pulled, not copied")
        #expect(fixture.engine.blobExchange.isWanted(plainHash))
    }

    @Test func aBlobRequestNeverOpensOurSealedCopy() throws {
        let fixture = EngineFixture(alice)
        _ = try holdingBobsSealedCopy(fixture)
        fixture.deliver(bob.blobRequest(for: plainHash.string, id: "breq-1"), from: bob)
        #expect(!fixture.stores.blobs.contains(plainHash), "a blobreq is signed by nobody")
        #expect(fixture.transport.files.isEmpty)
    }

    @Test func aKeyedFrameIsNeverCopied() throws {
        let fixture = EngineFixture(alice)
        _ = try holdingBobsSealedCopy(fixture)
        let keyed = MessageContent(body: "", attachmentHash: plainHash.string, attachmentMime: "image/jpeg", attachmentKey: "aw==")
        fixture.deliver(try bob.directMessage("", to: alice, id: "dm-2", sentAt: EngineFixture.start, content: keyed), from: bob)
        #expect(!fixture.stores.blobs.contains(plainHash))
        #expect(fixture.engine.blobExchange.isWanted(plainHash))
    }

    @Test func aMessageWhoseSealedBlobIsAlreadyHereLearnsItsPlaintextAtOnce() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        let sealed = try #require(AttachmentCrypto.seal(picture))
        let hash = BlobHash(of: sealed.blob)
        fixture.stores.blobs.insert(sealed.blob, hash: hash, mime: "image/jpeg", storedAt: 1)
        let content = MessageContent(
            body: "", attachmentHash: hash.string, attachmentMime: "image/jpeg", attachmentKey: Base64.encode(sealed.key))
        fixture.deliver(try bob.directMessage("", to: alice, id: "dm-1", sentAt: EngineFixture.start, content: content), from: bob)
        #expect(fixture.stores.messages.message("dm-1")?.attachment?.plainHash == plainHash)
    }

    @Test func aStrangerToTheGroupItCameThroughIsPulledNotCopied() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, dave)
        try fixture.pin(bob)
        try fixture.pin(dave)
        let info = roster([bob, carol, alice], createdBy: bob)
        let sealed = try #require(AttachmentCrypto.seal(picture))
        let hash = BlobHash(of: sealed.blob)
        let content = MessageContent(
            body: "", attachmentHash: hash.string, attachmentMime: "image/jpeg", attachmentKey: Base64.encode(sealed.key))
        fixture.deliver(
            try bob.groupMessage("", in: info, to: [alice, carol], id: "gm-1", sentAt: EngineFixture.start, content: content), from: bob)
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: hash, mime: "image/jpeg", bytes: sealed.blob))
        fixture.deliver(try roomPost(by: dave, id: "post-1"), from: dave)
        #expect(!fixture.stores.blobs.contains(plainHash) && fixture.engine.blobExchange.isWanted(plainHash))
    }

    @Test func aCopyWhoseBlobWentIsPulledInstead() throws {
        let fixture = EngineFixture(alice)
        let held = try holdingBobsSealedCopy(fixture)
        fixture.stores.blobs.remove(held.hash)
        fixture.deliver(try roomPost(by: bob, id: "post-1"), from: bob)
        #expect(!fixture.stores.blobs.contains(plainHash) && fixture.engine.blobExchange.isWanted(plainHash))
    }

    @Test func theOriginalOfARoomPostWeMadeFindsItsPublicName() throws {
        let fixture = EngineFixture(alice)
        let original = Array("the camera's own file".utf8)
        let photo = OutgoingPhoto(bytes: picture, mime: "image/webp", sourceHash: BlobHash(of: original))
        _ = try #require(fixture.engine.postToRoom("", photo: photo))
        let found = try #require(fixture.engine.heldPhoto(picked: original))
        #expect(found.bytes == picture && found.identity == PhotoIdentity(hash: plainHash, key: nil))
    }
}
