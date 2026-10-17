import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A blob stays while a live frame our custody carries names it in the clear, whoever sent the frame (ADR 2026-10.5sk9's
/// P7c amendment): Kotlin's `forward.countByAttachmentHash` in `BlobRepository.deleteIfUnreferenced`
/// (`BlobRepository.kt:100-112`) and the `forward_store` clause of `BlobDao.orphanHashes` (`BlobDao.kt:59-67`), at knit-next
/// `cbf2a487`. With the ratchet's switch on, our sealed profiles name our photo beside the seal, so after the photo changes
/// an Android newcomer back-filled with the old ones asks for the old photo, and we serve it as an Android author would.
@Suite struct MeshEngineCarriedPhotoTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let bob = TestPeer(seed: 4)
    private var now: Int64 { EngineFixture.start }

    private let old: [UInt8] = Array("the photo we had".utf8)
    private let new: [UInt8] = Array("the photo we have now".utf8)

    /// A day and a minute on: every frame dated `now` has left every custody.
    private var aDayOn: Int64 { now + CustodyLimits().ttlMilliseconds + 60_000 }

    /// Stores of `kind`, refusing nothing, with the SQL blob store's files under `directory`.
    private func stores(_ kind: StoreKind, in directory: URL) throws -> MeshStores {
        try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record).0
    }

    /// The states `fixture` answered `asker`'s holder query for `hash` with, and the files a blob request then streamed.
    private func ask(_ fixture: EngineFixture, as asker: TestPeer, for hash: BlobHash, tag: String) throws -> (
        states: [BlobHolding], files: [SentFile]
    ) {
        fixture.transport.clear()
        fixture.deliver(asker.blobHave([hash.string], id: "q-\(tag)"), from: asker)
        let answers = try fixture.transport.written(.blobHas).map { try BlobHasContent(decoding: $0.envelope.payload) }
        fixture.deliver(asker.blobRequest(for: hash.string, id: "breq-\(tag)"), from: asker)
        return (answers.flatMap { $0.items.map(\.state) }, fixture.transport.files.filter { $0.hash == hash })
    }

    /// The live `chat` frames in `stores`' custody that name `hash` in the clear.
    private func carried(naming hash: BlobHash, in stores: MeshStores, at wall: Int64) -> [CarriedFrame] {
        stores.custody.liveFrames(now: wall).filter { frame in
            frame.envelope.type == .chat && (try? ChatContent(decoding: frame.envelope.payload))?.attachmentHash == hash.string
        }
    }

    /// The switch on, over both store kinds. Our photo changes while the sealed profile that named the old one is in our
    /// custody: the old bytes stay, Carol, a newcomer asking for the hash that frame names, is told HAVE and served them,
    /// and once the frame's day is over the start's sweep removes them, so the next ask is told NONE and streams nothing.
    @Test(arguments: StoreKind.allCases)
    func ourReplacedPhotoIsServedWhileOurSealedProfileStillNamesIt(kind: StoreKind) throws {
        let directory = scratchDirectory("carried-photo")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = try stores(kind, in: directory)
        let keychain = KeptSecretStore(me.keys.storedForm)
        let fixture = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        fixture.deliver(try android.dm("hello", to: me, prekey: try fixture.ourPrekey(), id: "dm-1", sentAt: now), from: android)
        #expect(fixture.ratchetRecords(of: alice).session?.confirmed == true)

        let oldHash = BlobHash(of: old)
        fixture.engine.setAvatar(old)
        let sealed = try #require(carried(naming: oldHash, in: stores, at: now).first, "our sealed profile names the photo")
        #expect(sealed.envelope.recipientId == alice.nodeId.string && sealed.envelope.senderId == me.nodeId.string)
        fixture.engine.setAvatar(new)
        #expect(stores.ownProfile.load().avatarHash == BlobHash(of: new))
        #expect(stores.blobs.contains(oldHash), "kept while our custody carries a frame naming it")

        fixture.link(carol)
        let served = try ask(fixture, as: carol, for: oldHash, tag: "1")
        #expect(served.states == [.have])
        #expect(served.files == [SentFile(kind: .attachment, hash: oldHash, mime: "image/jpeg", bytes: old, to: carol.nodeId)])

        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: aDayOn)
        #expect(!stores.custody.contains(sealed.envelope.id), "the frame's day is over")
        #expect(!stores.blobs.contains(oldHash), "and the start's sweep removed the photo")
        #expect(stores.blobs.contains(BlobHash(of: new)), "our photo stays")
        restarted.link(carol)
        let refused = try ask(restarted, as: carol, for: oldHash, tag: "2")
        #expect(refused.states == [.notHeld] && refused.files.isEmpty)
    }

    /// The rule is Kotlin's whole: a frame from anyone keeps a blob we hold. Carol's DM to Bob, which we carry, names a blob
    /// we fetched on an asker's behalf. A release keeps it, and so does a start while the frame lives; the first start after
    /// its day removes it.
    @Test(arguments: StoreKind.allCases)
    func aFrameWeCarryForOthersKeepsABlobWeHold(kind: StoreKind) throws {
        let directory = scratchDirectory("carried-photo")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = try stores(kind, in: directory)
        let fixture = EngineFixture(me, stores: stores)
        try fixture.pin(carol)
        let photo = BlobHash(of: old)
        stores.blobs.insert(old, hash: photo, mime: "image/jpeg", storedAt: now)

        let sealed = try carol.directMessage("look", to: bob, id: "dm-carol-bob", sentAt: now)
        var chat = try ChatContent(decoding: sealed.envelope.payload)
        chat.attachmentHash = photo.string
        var envelope = sealed.envelope
        envelope.payload = chat.encoded
        fixture.deliver(try carol.signed(envelope), from: bob)
        #expect(stores.custody.contains("dm-carol-bob"))
        #expect(stores.messages.attachmentHashes().isEmpty, "no row of ours names it")

        fixture.engine.releaseBlob(photo)
        #expect(stores.blobs.contains(photo), "a release keeps it")
        _ = EngineFixture(me, stores: stores, wall: now + 60_000)
        #expect(stores.blobs.contains(photo), "so does a start while the frame lives")
        _ = EngineFixture(me, stores: stores, wall: aDayOn)
        #expect(!stores.custody.contains("dm-carol-bob") && !stores.blobs.contains(photo), "and the first start after its day not")
    }

    /// The switch off: no frame of ours names our photo, so the photo it replaced goes at once, as before, and Carol's ask
    /// is told NONE and makes us want it on her behalf. Nothing else on the air moved: the edit sends one cleartext profile and
    /// no `chat` frame.
    @Test func withTheSwitchOffAReplacedPhotoGoesAtOnceAsBefore() throws {
        let fixture = EngineFixture(me)
        fixture.link(carol)
        let oldHash = BlobHash(of: old)
        fixture.engine.setAvatar(old)
        fixture.transport.clear()
        fixture.engine.setAvatar(new)
        #expect(fixture.transport.written(.profile).count == 1 && fixture.transport.written(.chat).isEmpty)
        #expect(!fixture.stores.blobs.contains(oldHash))
        let refused = try ask(fixture, as: carol, for: oldHash, tag: "1")
        #expect(refused.states == [.notHeld] && refused.files.isEmpty)
        #expect(fixture.engine.blobExchange.isWanted(oldHash), "the ask is today's: wanted on her behalf")
    }

    /// The switch off, over both store kinds: custody's gate reads no switch, so we still carry the sealed profiles an
    /// Android peer sends its own sessions, and each names its photo beside the seal. When that peer's photo changes, the
    /// one it replaced stays while we carry them, and we serve it, as an Android carrier does; the first start after their
    /// day removes it.
    @Test(arguments: StoreKind.allCases)
    func withTheSwitchOffAPeersReplacedPhotoStaysWhileItsSealedProfilesWeCarryNameIt(kind: StoreKind) throws {
        let directory = scratchDirectory("carried-photo")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = try stores(kind, in: directory)
        let fixture = EngineFixture(me, stores: stores)
        #expect(!fixture.engine.configuration.ratchet)
        let android = try AndroidPeer(alice)
        let photoA = BlobHash(of: old)
        let photoB = BlobHash(of: new)
        let first = try alice.profile(
            version: 1, publishedAt: now, avatarHash: photoA.string, capabilities: AndroidPeer.capabilities, prekey: android.prekey.info)
        fixture.deliver(first, from: alice)
        fixture.engine.receiveFile(InboundFile(from: alice.nodeId, kind: .avatar, hash: photoA, mime: "image/jpeg", bytes: old))
        #expect(stores.peers.peer(alice.nodeId)?.avatarHash == photoA, "her photo A is shown")

        // Her sealed profile to Bob, another Android phone, which we can't open and carry: her photo beside the seal.
        let bobPhone = try AndroidPeer(bob)
        let bobPrekey = try #require(PeerPrekey(verifying: bobPhone.prekey.info, signedBy: bob.keys.bundle))
        let payload = ProfilePayload(name: "Android", status: "", avatarHash: photoA.string, version: 1, openToChat: false)
        let content = MessageContent(body: "", ctl: MessageContent.Control.profile, pr: payload)
        let sealed = try android.dm(content, to: bob, prekey: bobPrekey, id: "alice-profile-to-bob", sentAt: now, v3: true)
        var chat = try ChatContent(decoding: sealed.envelope.payload)
        chat.attachmentHash = photoA.string
        var envelope = sealed.envelope
        envelope.payload = chat.encoded
        fixture.deliver(try alice.signed(envelope), from: bob)
        #expect(stores.custody.contains("alice-profile-to-bob"))

        let prekey = android.prekey.info
        let second = try alice.profile(
            version: 2, publishedAt: now + 1, avatarHash: photoB.string, capabilities: AndroidPeer.capabilities, prekey: prekey)
        fixture.deliver(second, from: alice)
        fixture.engine.receiveFile(InboundFile(from: alice.nodeId, kind: .avatar, hash: photoB, mime: "image/jpeg", bytes: new))
        #expect(stores.peers.peer(alice.nodeId)?.avatarHash == photoB, "she shows B now")
        #expect(stores.blobs.contains(photoA), "A stays while a frame we carry names it")

        fixture.link(carol)
        let served = try ask(fixture, as: carol, for: photoA, tag: "1")
        #expect(served.states == [.have])
        #expect(served.files == [SentFile(kind: .attachment, hash: photoA, mime: "image/jpeg", bytes: old, to: carol.nodeId)])

        let restarted = EngineFixture(me, stores: stores, wall: aDayOn)
        #expect(!stores.custody.contains("alice-profile-to-bob") && !stores.blobs.contains(photoA), "gone at the start after its day")
        #expect(stores.blobs.contains(photoB))
        restarted.link(carol)
        let refused = try ask(restarted, as: carol, for: photoA, tag: "2")
        #expect(refused.states == [.notHeld] && refused.files.isEmpty)
    }
}
