import KnitCrypto
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A saved JPEG picked again after Photos rewrote its EXIF goes as the blob this phone holds (ADR 2026-10.f3mv, #12):
/// found by the EXIF-less name Save wrote, checked against the opened plaintext, and never by anything a peer can send.
extension MeshEngineIdentityTests {
    private struct Exifless {
        let alice = TestPeer(seed: 1)
        let bob = TestPeer(seed: 2)
        let carol = TestPeer(seed: 3)
        /// The picture as Knit for Android sent it, its EXIF Android's.
        let original = JPEGFixture.jpeg(exif: [JPEGFixture.androidExif])
        /// The same picture as Photos handed it back, its EXIF rewritten.
        let picked = JPEGFixture.jpeg(exif: [JPEGFixture.appleExif])

        /// Bob's DM to Alice, `id`, carrying the picture `sealed` holds, delivered and its blob landed.
        func holdBobsSealedCopy(
            _ fixture: EngineFixture, id: String, sealed: AttachmentCrypto.Sealed
        ) throws -> MessageAttachment {
            fixture.befriend(bob)
            let hash = BlobHash(of: sealed.blob)
            let content = MessageContent(
                body: "", attachmentHash: hash.string, attachmentMime: "image/jpeg", attachmentKey: Base64.encode(sealed.key))
            fixture.deliver(
                try bob.directMessage("", to: alice, id: frameIdOf(id), sentAt: EngineFixture.start, content: content), from: bob)
            fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: hash, mime: "image/jpeg", bytes: sealed.blob))
            _ = fixture.engine.drainEvents()
            fixture.transport.clear()
            return try #require(fixture.stores.messages.message(frameIdOf(id))?.attachment)
        }

        /// ``holdBobsSealedCopy(_:id:sealed:)`` of ``original``, sealed afresh, after linking and pinning Bob.
        func holdBobsSealedCopy(_ fixture: EngineFixture) throws -> MessageAttachment {
            fixture.link(bob)
            try fixture.pin(bob)
            let sealed = try #require(AttachmentCrypto.seal(original))
            return try holdBobsSealedCopy(fixture, id: "dm-1", sealed: sealed)
        }

        /// Saves `held` as `AppSession.attachmentToSave` does: names its plaintext's EXIF-less hash on its (hash, key).
        func save(_ held: MessageAttachment, plaintext: [UInt8], in fixture: EngineFixture) throws {
            let name = try #require(ExiflessJPEG.name(of: plaintext))
            fixture.stores.messages.setAttachmentExiflessHash(held.hash, key: held.key, to: name.hash)
        }

        /// A room post from `author`, `id`, naming the blob `hash`.
        func roomPost(by author: TestPeer, id: String, naming hash: BlobHash) throws -> TestFrame {
            let post = ChatContent(body: "", attachmentHash: hash.string, attachmentMime: "image/jpeg")
            return try author.signed(
                RelayEnvelope(
                    type: .chat, id: frameIdOf(id), senderId: author.nodeId.string, sentAt: EngineFixture.start, payload: post.encoded))
        }

        /// The EXIF-less hash of ``original`` and ``picked`` alike.
        var exiflessHash: BlobHash {
            ExiflessJPEG.name(of: original)?.hash ?? .empty
        }
    }

    // MARK: Found

    @Test func aPickThatDiffersOnlyInExifGoesAsTheHeldSealedPhoto() throws {
        let parts = Exifless()
        let fixture = EngineFixture(parts.alice)
        let held = try parts.holdBobsSealedCopy(fixture)
        #expect(BlobHash(of: parts.picked) != BlobHash(of: parts.original), "Photos changed the hash")
        #expect(fixture.engine.heldPhoto(picked: parts.picked) == nil, "not yet saved, nothing names it")
        try parts.save(held, plaintext: parts.original, in: fixture)
        let found = try #require(fixture.engine.heldPhoto(picked: parts.picked))
        let expected = OutgoingPhoto(
            bytes: parts.original,
            mime: "image/jpeg",
            identity: PhotoIdentity(hash: held.hash, key: held.key),
            sourceHash: BlobHash(of: parts.picked)
        )
        #expect(found == expected)
        let blobs = fixture.stores.blobs.allHashes()
        try fixture.pin(parts.carol)
        let sent = try #require(fixture.engine.sendDirectMessage("", to: parts.carol.nodeId, photo: found)?.attachment)
        #expect(sent.hash == held.hash && sent.key == held.key && sent.plainHash == BlobHash(of: parts.original))
        #expect(sent.sourceHash == BlobHash(of: parts.picked) && sent.exiflessHash == nil, "Save alone writes the name")
        #expect(fixture.stores.blobs.allHashes() == blobs, "nothing sealed again")
        // The next pick of the same Photos file now matches exactly, by the source the send remembered.
        #expect(fixture.stores.messages.identities(matching: BlobHash(of: parts.picked)).map(\.hash) == [held.hash])
        #expect(fixture.engine.heldPhoto(picked: parts.picked)?.identity == PhotoIdentity(hash: held.hash, key: held.key))
    }

    @Test func aPickThatDiffersOnlyInExifGoesAsTheHeldRoomPost() throws {
        let parts = Exifless()
        let fixture = EngineFixture(parts.alice)
        fixture.link(parts.bob)
        try fixture.pin(parts.bob)
        let hash = BlobHash(of: parts.original)
        fixture.deliver(try parts.roomPost(by: parts.bob, id: "post-1", naming: hash), from: parts.bob)
        fixture.engine.receiveFile(
            InboundFile(from: parts.bob.nodeId, kind: .attachment, hash: hash, mime: "image/jpeg", bytes: parts.original))
        let held = try #require(fixture.stores.messages.message(frameIdOf("post-1"))?.attachment)
        try parts.save(held, plaintext: parts.original, in: fixture)
        let found = try #require(fixture.engine.heldPhoto(picked: parts.picked))
        #expect(found.identity == PhotoIdentity(hash: hash, key: nil) && found.bytes == parts.original)
        #expect(found.sourceHash == BlobHash(of: parts.picked))
    }

    @Test func anExactMatchStillWins() throws {
        let parts = Exifless()
        let fixture = EngineFixture(parts.alice)
        let held = try parts.holdBobsSealedCopy(fixture)
        try parts.save(held, plaintext: parts.original, in: fixture)
        // The original itself matches its plaintext's name, and goes as it is.
        #expect(fixture.engine.heldPhoto(picked: parts.original)?.sourceHash == nil)
        // A send of ours that the same picked bytes went out as is the exact match, and wins over the EXIF-less one.
        let prepared = Array("what preparing made of the pick".utf8)
        let ours = OutgoingPhoto(bytes: prepared, mime: "image/webp", sourceHash: BlobHash(of: parts.picked))
        let sent = try #require(fixture.engine.sendDirectMessage("", to: parts.carol.nodeId, photo: ours)?.attachment)
        let found = try #require(fixture.engine.heldPhoto(picked: parts.picked))
        #expect(found.identity == PhotoIdentity(hash: sent.hash, key: sent.key) && found.bytes == prepared)
    }

    // MARK: Not found

    @Test func anotherOrientationOtherPixelsAndAGoneBlobMatchNothing() throws {
        let parts = Exifless()
        let fixture = EngineFixture(parts.alice)
        let held = try parts.holdBobsSealedCopy(fixture)
        try parts.save(held, plaintext: parts.original, in: fixture)
        // Photos turned it: the same pixels a quarter turn apart.
        let turned = JPEGFixture.jpeg(exif: [JPEGFixture.exif(JPEGFixture.orientationTIFF(6, little: false))])
        #expect(ExiflessJPEG.name(of: turned)?.hash == parts.exiflessHash)
        #expect(fixture.engine.heldPhoto(picked: turned) == nil)
        let otherPixels = JPEGFixture.jpeg(exif: [JPEGFixture.appleExif], scan: [0x12, 0x34])
        #expect(fixture.engine.heldPhoto(picked: otherPixels) == nil)
        #expect(fixture.engine.heldPhoto(picked: Array("no JPEG at all".utf8)) == nil)
        fixture.stores.blobs.remove(held.hash)
        #expect(fixture.engine.heldPhoto(picked: parts.picked) == nil, "its blob went")
    }

    @Test func aRowWhoseStoredNameNoLongerFitsItsPlaintextNeverAnswers() throws {
        // The stored name is never trusted: a key-less row naming the sealed blob's hash opens to ciphertext, which names
        // nothing, and a row named by a picture it does not hold opens to one whose name differs.
        let parts = Exifless()
        let fixture = EngineFixture(parts.alice)
        let held = try parts.holdBobsSealedCopy(fixture)
        let keyless = MessageAttachment(hash: held.hash, mime: "image/jpeg", exiflessHash: parts.exiflessHash)
        let post = MessageRecord(
            id: frameIdOf("post-1"),
            senderId: parts.bob.nodeId,
            recipientId: nil,
            conversationId: Conversations.nearby,
            body: "",
            sentAt: 1,
            attachment: keyless
        )
        fixture.stores.messages.save(post)
        #expect(fixture.stores.messages.identities(exifless: parts.exiflessHash).map(\.key) == [nil])
        #expect(fixture.engine.heldPhoto(picked: parts.picked) == nil)
        let other = JPEGFixture.jpeg(scan: [0x56, 0x78])
        fixture.stores.messages.setAttachmentExiflessHash(held.hash, key: held.key, to: ExiflessJPEG.name(of: other)?.hash ?? .empty)
        #expect(fixture.engine.heldPhoto(picked: other) == nil)
    }

    @Test func aBlobInManyRowsIsOpenedOnceAPick() throws {
        let parts = Exifless()
        let base = MeshStores.inMemory()
        let counted = CountingBlobStore(base.blobs)
        let stores = MeshStores(
            custody: base.custody,
            peers: base.peers,
            messages: base.messages,
            conversations: base.conversations,
            blocks: base.blocks,
            groups: base.groups,
            ownProfile: base.ownProfile,
            blobs: counted,
            ratchet: base.ratchet,
            groupRatchet: base.groupRatchet,
            presenceKeys: base.presenceKeys,
            transactor: base.transactor
        )
        let fixture = EngineFixture(parts.alice, stores: stores)
        fixture.link(parts.bob)
        try fixture.pin(parts.bob)
        let sealed = try #require(AttachmentCrypto.seal(parts.original))
        var held: MessageAttachment?
        for index in 0..<20 {
            held = try parts.holdBobsSealedCopy(fixture, id: "dm-\(index)", sealed: sealed)
        }
        let copy = try #require(held)
        try parts.save(copy, plaintext: parts.original, in: fixture)
        #expect(fixture.stores.messages.identities(exifless: parts.exiflessHash).count == 16)
        let turned = JPEGFixture.jpeg(exif: [JPEGFixture.exif(JPEGFixture.orientationTIFF(3, little: true))])
        counted.reads = 0
        #expect(fixture.engine.heldPhoto(picked: turned) == nil)
        #expect(counted.reads == 1, "one (blob, key) pair, opened once")
    }

    // MARK: What a peer can set off

    @Test func theDmPeerPostingTheExiflessBytesIsPulledNotCopied() throws {
        // Bob is party to the DM the sealed copy came through, so a copy from our own store would be his to set off, but
        // only for the plaintext the copy names. The EXIF-less bytes are another file, and the name is never a copy's.
        let parts = Exifless()
        let fixture = EngineFixture(parts.alice)
        let held = try parts.holdBobsSealedCopy(fixture)
        try parts.save(held, plaintext: parts.original, in: fixture)
        let kept = try #require(ExiflessJPEG.read(parts.original)?.kept)
        #expect(BlobHash(of: kept) == parts.exiflessHash)
        let keyless = MessageContent(body: "", attachmentHash: parts.exiflessHash.string, attachmentMime: "image/jpeg")
        fixture.deliver(
            try parts.bob.directMessage("", to: parts.alice, id: frameIdOf("dm-2"), sentAt: EngineFixture.start, content: keyless),
            from: parts.bob)
        #expect(!fixture.stores.blobs.contains(parts.exiflessHash), "nothing copied")
        #expect(fixture.engine.blobExchange.isWanted(parts.exiflessHash), "wanted as any picture we lack")
    }

    @Test func aBlobRequestForTheExiflessNameIsServedNothing() throws {
        let parts = Exifless()
        let fixture = EngineFixture(parts.alice)
        let held = try parts.holdBobsSealedCopy(fixture)
        try parts.save(held, plaintext: parts.original, in: fixture)
        fixture.deliver(parts.bob.blobRequest(for: parts.exiflessHash.string, id: frameIdOf("breq-1")), from: parts.bob)
        #expect(!fixture.stores.blobs.contains(parts.exiflessHash))
        #expect(fixture.transport.files.isEmpty)
    }
}

/// A blob store that counts the whole-blob reads it passes to the one it wraps.
private final class CountingBlobStore: BlobStore {
    private let held: any BlobStore
    private let counter = Lock(0)

    init(_ held: any BlobStore) {
        self.held = held
    }

    /// How many times a blob's bytes were read.
    var reads: Int {
        get { counter.withLock { $0 } }
        set { counter.withLock { $0 = newValue } }
    }

    func contains(_ hash: BlobHash) -> Bool { held.contains(hash) }
    func held(among hashes: Set<BlobHash>) -> Set<BlobHash> { held.held(among: hashes) }
    func mime(of hash: BlobHash) -> String? { held.mime(of: hash) }
    func size(of hash: BlobHash) -> Int? { held.size(of: hash) }

    func read(_ hash: BlobHash, offset: Int, count: Int) -> [UInt8]? {
        held.read(hash, offset: offset, count: count)
    }

    func bytes(of hash: BlobHash) -> [UInt8]? {
        reads += 1
        return held.bytes(of: hash)
    }

    func insert(_ bytes: [UInt8], hash: BlobHash, mime: String, storedAt: Int64) -> Bool {
        held.insert(bytes, hash: hash, mime: mime, storedAt: storedAt)
    }

    func remove(_ hash: BlobHash) {
        held.remove(hash)
    }

    func allHashes() -> [BlobHash] { held.allHashes() }
    func hashes(storedBefore cutoff: Int64) -> [BlobHash] { held.hashes(storedBefore: cutoff) }
    func totalBytes(among hashes: Set<BlobHash>) -> Int { held.totalBytes(among: hashes) }
}
