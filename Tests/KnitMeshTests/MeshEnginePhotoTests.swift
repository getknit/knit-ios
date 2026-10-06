import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// Photos in chats (`MeshManager.sendChat` and `InboundPipeline.deliverChat` in knit-next; ADR 2026-10.nh55): public
/// in the room, sealed in DMs and groups, fetched when they arrive without their bytes, and kept while a message names
/// them.
@Suite struct MeshEnginePhotoTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    private let jpeg = OutgoingPhoto(bytes: Array("a photo from the trail".utf8), mime: "image/jpeg")

    /// The sealed content of a DM `written` carried, as `reader` opens it.
    private func openedDirect(_ written: Written, as reader: TestPeer) throws -> MessageContent? {
        let envelope = written.envelope
        let enc = try #require(try ChatContent(decoding: envelope.payload).enc)
        let header = MessageCrypto.header(
            id: envelope.id, senderId: envelope.senderId, sentAt: envelope.sentAt, thread: try #require(envelope.recipientId))
        return MessageCrypto.open(enc, header: header, as: reader.keys)
    }

    // MARK: Sending

    @Test func aRoomPhotoGoesInTheClearUnderItsOwnHash() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.transport.clear()
        let record = try #require(fixture.engine.postToRoom("Look at this", photo: jpeg))
        let hash = BlobHash(of: jpeg.bytes)
        #expect(record.attachment == MessageAttachment(hash: hash, mime: "image/jpeg"))
        #expect(fixture.stores.blobs.bytes(of: hash) == jpeg.bytes, "kept for whoever asks")
        #expect(fixture.stores.messages.message(record.id) == record)
        let chat = try ChatContent(decoding: try #require(fixture.transport.written(.chat).first).envelope.payload)
        #expect(chat.body == "Look at this" && chat.attachmentHash == hash.string && chat.attachmentMime == "image/jpeg")
        #expect(chat.enc == nil)
    }

    /// A photo needs no words, and one too heavy for a FILE record is not sent at all.
    @Test func aPhotoNeedsNoCaptionAndATooHeavyOneIsNotSent() throws {
        let fixture = EngineFixture(alice)
        let bare = try #require(fixture.engine.postToRoom("  ", photo: jpeg))
        #expect(bare.body.isEmpty && bare.attachment != nil)
        let heavy = OutgoingPhoto(bytes: [UInt8](repeating: 0, count: OutgoingPhoto.maxBytes + 1), mime: "image/jpeg")
        #expect(fixture.engine.postToRoom("too much", photo: heavy) == nil)
        #expect(fixture.engine.sendDirectMessage("too much", to: bob.nodeId, photo: heavy) == nil)
        #expect(fixture.engine.postToRoom("  ") == nil, "still nothing to send without one")
    }

    /// The blob is the ciphertext, and only the sealed content says how to open it; the cleartext names the hash
    /// alone, so a carrier can pull the blob it carries (`MeshManager.kt:1112-1128`).
    @Test func aDMPhotoIsSealedAndOnlyItsHashTravelsInTheClear() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        fixture.transport.clear()
        let record = try #require(fixture.engine.sendDirectMessage("For you", to: bob.nodeId, photo: jpeg))
        let attachment = try #require(record.attachment)
        let blob = try #require(fixture.stores.blobs.bytes(of: attachment.hash))
        #expect(attachment.hash == BlobHash(of: blob) && blob != jpeg.bytes, "the ciphertext, under its own hash")
        let key = try #require(attachment.key.flatMap { Base64.decode($0) })
        #expect(AttachmentCrypto.open(blob, key: key) == jpeg.bytes)
        let sent = try #require(fixture.transport.written(.chat).first)
        let chat = try ChatContent(decoding: sent.envelope.payload)
        #expect(chat.attachmentHash == attachment.hash.string && chat.attachmentMime == nil && chat.body.isEmpty)
        let content = try #require(try openedDirect(sent, as: bob))
        #expect(content.body == "For you")
        #expect(content.attachmentHash == attachment.hash.string && content.attachmentMime == "image/jpeg")
        #expect(content.attachmentKey == attachment.key)
    }

    /// A DM that waits for its recipient's key keeps its photo, and goes out with it once the key pins.
    @Test func aPendingDMKeepsItsPhotoUntilTheKeyPins() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        let record = try #require(fixture.engine.sendDirectMessage("", to: bob.nodeId, photo: jpeg))
        #expect(record.pendingKey && record.attachment?.key != nil)
        try fixture.pin(bob)
        let sent = try #require(fixture.transport.written(.chat).first { $0.envelope.id == record.id })
        let content = try #require(try openedDirect(sent, as: bob))
        #expect(content.attachmentHash == record.attachment?.hash.string && content.attachmentKey == record.attachment?.key)
        #expect(try ChatContent(decoding: sent.envelope.payload).attachmentHash == record.attachment?.hash.string)
    }

    @Test func aGroupPhotoIsSealedToEveryMemberAndAPendingOneKeepsIt() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        fixture.transport.clear()
        let record = try #require(fixture.engine.sendGroupMessage("All of us", to: group.id, photo: jpeg))
        let sent = try #require(fixture.transport.written(.chat).first)
        let content = try #require(try opened(sent, as: bob))
        #expect(content.attachmentHash == record.attachment?.hash.string && content.attachmentKey == record.attachment?.key)
        #expect(try ChatContent(decoding: sent.envelope.payload).attachmentHash == record.attachment?.hash.string)

        // Carol's key has not pinned; a group of her alone waits, and keeps the photo for when it pins.
        let solo = try #require(fixture.engine.createGroup(with: [carol.nodeId]))
        let waiting = try #require(fixture.engine.sendGroupMessage("", to: solo.id, photo: jpeg))
        #expect(waiting.pendingKey)
        fixture.transport.clear()
        try fixture.pin(carol)
        let flushed = try #require(fixture.transport.written(.chat).first { $0.envelope.id == waiting.id })
        #expect(try opened(flushed, as: carol)?.attachmentKey == waiting.attachment?.key)
    }

    // MARK: Receiving

    @Test func aRoomPhotoIsKeptWithItsMessageAndFetched() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        fixture.transport.clear()
        let hash = BlobHash(of: jpeg.bytes)
        let post = ChatContent(body: "Sunset", attachmentHash: hash.string, attachmentMime: "image/jpeg")
        let frame = try bob.signed(
            RelayEnvelope(type: .chat, id: "post-1", senderId: bob.nodeId.string, sentAt: EngineFixture.start, payload: post.encoded))
        fixture.deliver(frame, from: bob)
        #expect(fixture.stores.messages.message("post-1")?.attachment == MessageAttachment(hash: hash, mime: "image/jpeg"))
        let asked = fixture.transport.written(.blobRequest)
        #expect(try asked.map { try BlobRequestContent(decoding: $0.envelope.payload).hash } == [hash.string])
        _ = fixture.engine.drainEvents()

        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: hash, mime: "image/jpeg", bytes: jpeg.bytes))
        #expect(fixture.stores.blobs.bytes(of: hash) == jpeg.bytes)
        #expect(fixture.engine.drainEvents() == [.attachmentArrived(hash)])
    }

    @Test func aDMPhotoKeepsTheKeyItsSealedContentCarries() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        let sealed = try #require(AttachmentCrypto.seal(jpeg.bytes))
        let hash = BlobHash(of: sealed.blob)
        let content = MessageContent(
            body: "", attachmentHash: hash.string, attachmentMime: "image/png", attachmentKey: Base64.encode(sealed.key))
        fixture.deliver(try bob.directMessage("", to: alice, id: "dm-1", sentAt: EngineFixture.start, content: content), from: bob)
        let attachment = try #require(fixture.stores.messages.message("dm-1")?.attachment)
        #expect(attachment == MessageAttachment(hash: hash, mime: "image/png", key: Base64.encode(sealed.key)))
        #expect(fixture.engine.blobExchange.isWanted(hash))
    }

    /// Android forwards a room picture into a DM under the room's own hash, with no key (knit-next ADR 2026-10.mptm): a
    /// null key has always meant a plaintext blob, so the message keeps the hash alone and the photo is fetched as is.
    /// Many messages may name that one blob.
    @Test func aSealedMessageMayNameAPhotoWithNoKeyWhichIsThePlaintextBlob() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        let hash = BlobHash(of: jpeg.bytes)
        let content = MessageContent(body: "look", attachmentHash: hash.string, attachmentMime: "image/jpeg")
        fixture.deliver(try bob.directMessage("look", to: alice, id: "dm-1", sentAt: EngineFixture.start, content: content), from: bob)
        let room = ChatContent(body: "", attachmentHash: hash.string, attachmentMime: "image/jpeg")
        let post = RelayEnvelope(type: .chat, id: "post-1", senderId: bob.nodeId.string, sentAt: EngineFixture.start, payload: room.encoded)
        fixture.deliver(try bob.signed(post), from: bob)
        #expect(fixture.stores.messages.message("dm-1")?.attachment == MessageAttachment(hash: hash, mime: "image/jpeg"))
        #expect(fixture.engine.blobExchange.isWanted(hash))
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: hash, mime: "image/jpeg", bytes: jpeg.bytes))
        #expect(fixture.stores.blobs.bytes(of: hash) == jpeg.bytes, "the plaintext itself, opened by nothing")
        #expect(fixture.engine.drainEvents().contains(.attachmentArrived(hash)))
    }

    /// A file arrives with its name and size, which only a file carries; this build shows it as a label.
    @Test func aFileKeepsItsNameAndSize() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let hash = BlobHash(of: Array("a pdf".utf8))
        let content = MessageContent(
            body: "",
            attachmentHash: hash.string,
            attachmentMime: "application/pdf",
            attachmentKey: "aw==",
            attachmentName: "map.pdf",
            attachmentSize: 2048
        )
        fixture.deliver(try bob.directMessage("", to: alice, id: "dm-file", sentAt: EngineFixture.start, content: content), from: bob)
        #expect(fixture.stores.messages.message("dm-file")?.attachment?.name == "map.pdf")
        #expect(fixture.stores.messages.message("dm-file")?.attachment?.size == 2048)
    }

    /// A hash that is not 64 lowercase hex digits names no blob, so the message carries nothing, and a peer's long type
    /// is cut, since a frame bounds nothing on its own.
    @Test func aMalformedHashCarriesNothingAndALongTypeIsCut() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let bad = ChatContent(body: "odd", attachmentHash: "NOT-A-HASH", attachmentMime: "image/jpeg")
        let frame = try bob.signed(
            RelayEnvelope(type: .chat, id: "post-bad", senderId: bob.nodeId.string, sentAt: EngineFixture.start, payload: bad.encoded))
        fixture.deliver(frame, from: bob)
        #expect(fixture.stores.messages.message("post-bad")?.attachment == nil)
        let long = ChatContent(
            body: "", attachmentHash: BlobHash(of: jpeg.bytes).string, attachmentMime: String(repeating: "x", count: 5000))
        let frame2 = try bob.signed(
            RelayEnvelope(type: .chat, id: "post-long", senderId: bob.nodeId.string, sentAt: EngineFixture.start, payload: long.encoded))
        fixture.deliver(frame2, from: bob)
        #expect(fixture.stores.messages.message("post-long")?.attachment?.mime?.utf16.count == MeshEngine.attachmentTextLimit)
    }

    // MARK: Keeping and fetching

    /// A message's photo is wanted at every re-offer while its bytes are missing (knit-next ADR 2026-09.ptv8), and kept
    /// by the sweep while a message names it; once its thread goes, the next sweep takes it.
    @Test func aMessagesPhotoIsWantedWhileMissingAndKeptWhileNamed() throws {
        let fixture = EngineFixture(alice)
        let missing = BlobHash(of: Array("not here yet".utf8))
        fixture.stores.messages.save(
            MessageRecord(
                id: "m1",
                senderId: bob.nodeId,
                recipientId: nil,
                conversationId: Conversations.nearby,
                body: "",
                sentAt: 1,
                attachment: MessageAttachment(hash: missing)
            )
        )
        fixture.engine.rewantMissingBlobs(sparing: [])
        #expect(fixture.engine.blobExchange.isWanted(missing))
        #expect(fixture.engine.blobExchange.wants[missing]?.author == bob.nodeId, "asked of its sender first (`attachmentsNeedingFetch`)")

        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId]))
        let sent = try #require(fixture.engine.sendGroupMessage("", to: group.id, photo: jpeg))
        let hash = try #require(sent.attachment?.hash)
        fixture.engine.sweepUnreferencedBlobs()
        #expect(fixture.stores.blobs.contains(hash), "named by a message")
        fixture.engine.leaveGroup(group.id)
        fixture.engine.sweepUnreferencedBlobs()
        #expect(!fixture.stores.blobs.contains(hash), "its thread went")
    }
}
