import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// Profile photos: ours published and pushed, and a peer's adopted once its bytes are held (`MeshManager.broadcastProfile`
/// and `sendAvatarIfNeeded`, `InboundPipeline.onAvatarReceived`, `storeProfileRow` and `resolveAvatarHash` in
/// knit-next, with `ProfileUpdateLabTest.anAvatarCrossesWithTheProfile`; ADR 2026-10.nh55).
@Suite struct MeshEngineAvatarTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    private let jpeg: [UInt8] = Array("a 256-pixel JPEG, in spirit".utf8)
    private let newer: [UInt8] = Array("another photo".utf8)

    private func profile(of peer: TestPeer, photo: [UInt8]?, version: Int64, from fixture: EngineFixture) throws -> TestFrame {
        try peer.profile(
            version: version, publishedAt: fixture.clock.wallMilliseconds() + version, avatarHash: photo.map { BlobHash(of: $0).string })
    }

    // MARK: Ours

    @Test func ourPhotoIsPublishedThenPushedToEveryNeighbour() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        fixture.transport.clear()
        let before = fixture.stores.ownProfile.load()
        fixture.engine.setAvatar(jpeg)
        let hash = BlobHash(of: jpeg)
        let own = fixture.stores.ownProfile.load()
        #expect(own.avatarHash == hash)
        #expect(own.version > before.version && own.publishedAt > before.publishedAt, "an edit, with a new frame id")
        let flooded = try #require(fixture.transport.written(.profile).first)
        #expect(try ProfileContent(decoding: flooded.envelope.payload).avatarHash == hash.string)
        #expect(fixture.stores.blobs.bytes(of: hash) == jpeg)
        #expect(
            fixture.transport.files == [
                SentFile(kind: .avatar, hash: hash, mime: "image/jpeg", bytes: jpeg, to: bob.nodeId),
                SentFile(kind: .avatar, hash: hash, mime: "image/jpeg", bytes: jpeg, to: carol.nodeId),
            ])
    }

    @Test func thePhotoSetAgainChangesNothing() {
        let fixture = EngineFixture(alice)
        fixture.engine.setAvatar(jpeg)
        let version = fixture.stores.ownProfile.load().version
        fixture.engine.setAvatar(jpeg)
        #expect(fixture.stores.ownProfile.load().version == version)
    }

    @Test func aPushCountsOnlyOnceItIsOutWholeSoACutLinkPushesAgain() {
        let fixture = EngineFixture(alice)
        fixture.engine.setAvatar(jpeg)
        fixture.link(bob)
        #expect(fixture.transport.files.map(\.to) == [bob.nodeId])
        fixture.engine.linkDown(bob.nodeId)
        fixture.engine.linkUp(Neighbor(nodeId: bob.nodeId))
        #expect(fixture.transport.files.count == 2, "the first push never finished")
        fixture.engine.fileSent(BlobHash(of: jpeg), to: bob.nodeId)
        fixture.engine.linkUp(Neighbor(nodeId: bob.nodeId))
        #expect(fixture.transport.files.count == 2, "once per neighbour per photo")
    }

    @Test func thePhotoGoesOutRightBehindTheProfileAtLinkUp() {
        let fixture = EngineFixture(alice)
        fixture.engine.setAvatar(jpeg)
        fixture.transport.clear()
        fixture.link(bob)
        #expect(fixture.transport.written.first?.envelope.type == .profile)
        #expect(fixture.transport.files.first?.kind == .avatar)
    }

    @Test func clearingOurPhotoPublishesNoneAndLetsItsBytesGo() throws {
        let fixture = EngineFixture(alice)
        fixture.engine.setAvatar(jpeg)
        fixture.transport.clear()
        fixture.engine.setAvatar(nil)
        #expect(fixture.stores.ownProfile.load().avatarHash == nil)
        let flooded = try #require(fixture.transport.written(.profile).first)
        #expect(try ProfileContent(decoding: flooded.envelope.payload).avatarHash == nil)
        #expect(!fixture.stores.blobs.contains(BlobHash(of: jpeg)))
    }

    @Test func ourPhotoIsServedToAnyoneWhoAsks() {
        let fixture = EngineFixture(alice)
        fixture.engine.setAvatar(jpeg)
        fixture.link(bob)
        fixture.engine.fileSent(BlobHash(of: jpeg), to: bob.nodeId)
        fixture.transport.clear()
        fixture.deliver(bob.blobRequest(for: BlobHash(of: jpeg).string, id: "breq-1"), from: bob)
        #expect(fixture.transport.files.map(\.kind) == [.attachment], "a serve is an ATTACHMENT, whatever the blob")
    }

    // MARK: Theirs

    @Test func aStrangersPhotoIsAskedForAndShownOnceItsBytesArrive() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        fixture.transport.clear()
        fixture.deliver(try profile(of: bob, photo: jpeg, version: 5, from: fixture), from: carol)
        let hash = BlobHash(of: jpeg)
        var record = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(record.advertisedAvatarHash == hash && record.avatarHash == nil)
        #expect(fixture.transport.written(.blobRequest).map(\.to) == [carol.nodeId], "bob is not linked, so nobody will push it")
        _ = fixture.engine.drainEvents()
        // A pulled photo arrives as kind ATTACHMENT, as Android serves every blob.
        fixture.engine.receiveFile(InboundFile(from: carol.nodeId, kind: .attachment, hash: hash, mime: "image/jpeg", bytes: jpeg))
        record = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(record.avatarHash == hash)
        #expect(fixture.engine.drainEvents().contains(.peerUpdated(bob.nodeId)))
    }

    @Test func aLinkedPeersPhotoIsLeftToItsPushThenAdopted() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.transport.clear()
        fixture.deliver(try profile(of: bob, photo: jpeg, version: 5, from: fixture), from: bob)
        #expect(fixture.transport.written(.blobRequest).isEmpty)
        let hash = BlobHash(of: jpeg)
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .avatar, hash: hash, mime: "image/jpeg", bytes: jpeg))
        #expect(fixture.stores.peers.peer(bob.nodeId)?.avatarHash == hash)
    }

    @Test func aLostPushIsAskedForAtTheNextReoffer() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.deliver(try profile(of: bob, photo: jpeg, version: 5, from: fixture), from: bob)
        fixture.transport.clear()
        fixture.advance(60_000)
        #expect(fixture.transport.written(.blobRequest).map(\.to) == [bob.nodeId])
    }

    @Test func aPushThatIsNotTheAdvertisedPhotoIsDropped() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.deliver(try profile(of: bob, photo: jpeg, version: 5, from: fixture), from: bob)
        // Anyone can claim bob's node id in a HELLO; only the signed profile says which photo is bob's.
        fixture.engine.receiveFile(
            InboundFile(from: bob.nodeId, kind: .avatar, hash: BlobHash(of: newer), mime: "image/jpeg", bytes: newer))
        #expect(fixture.stores.peers.peer(bob.nodeId)?.avatarHash == nil)
        #expect(!fixture.stores.blobs.contains(BlobHash(of: newer)))
        #expect(fixture.engine.filesRejected == 1)
    }

    @Test func aPushFromAPeerWithNoProfileYetIsDropped() {
        let fixture = EngineFixture(alice)
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .avatar, hash: BlobHash(of: jpeg), mime: "image/jpeg", bytes: jpeg))
        #expect(fixture.stores.peers.peer(bob.nodeId) == nil)
        #expect(fixture.engine.filesRejected == 1)
    }

    @Test func aNewerPhotoWaitsForItsBytesAndTheOldOneShowsMeanwhile() throws {
        let fixture = EngineFixture(alice)
        fixture.stores.blobs.insert(jpeg, hash: BlobHash(of: jpeg), mime: "image/jpeg", storedAt: 1)
        fixture.deliver(try profile(of: bob, photo: jpeg, version: 5, from: fixture), from: bob)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.avatarHash == BlobHash(of: jpeg), "held already, so shown at once")
        fixture.deliver(try profile(of: bob, photo: newer, version: 6, from: fixture), from: bob)
        var record = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(record.avatarHash == BlobHash(of: jpeg) && record.advertisedAvatarHash == BlobHash(of: newer))
        fixture.engine.wantBlob(BlobHash(of: newer))
        fixture.engine.receiveFile(
            InboundFile(from: bob.nodeId, kind: .attachment, hash: BlobHash(of: newer), mime: "image/jpeg", bytes: newer))
        record = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(record.avatarHash == BlobHash(of: newer))
        #expect(!fixture.stores.blobs.contains(BlobHash(of: jpeg)), "the photo it replaced goes once nothing names it")
    }

    @Test func aNewerProfileWithNoPhotoClearsIt() throws {
        let fixture = EngineFixture(alice)
        fixture.stores.blobs.insert(jpeg, hash: BlobHash(of: jpeg), mime: "image/jpeg", storedAt: 1)
        fixture.deliver(try profile(of: bob, photo: jpeg, version: 5, from: fixture), from: bob)
        fixture.deliver(try profile(of: bob, photo: nil, version: 6, from: fixture), from: bob)
        let record = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(record.avatarHash == nil && record.advertisedAvatarHash == nil)
        #expect(!fixture.stores.blobs.contains(BlobHash(of: jpeg)))
    }

    @Test func anOlderProfileChangesNoPhoto() throws {
        let fixture = EngineFixture(alice)
        fixture.stores.blobs.insert(jpeg, hash: BlobHash(of: jpeg), mime: "image/jpeg", storedAt: 1)
        fixture.deliver(try profile(of: bob, photo: jpeg, version: 6, from: fixture), from: bob)
        fixture.deliver(try profile(of: bob, photo: nil, version: 5, from: fixture), from: bob)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.avatarHash == BlobHash(of: jpeg))
    }

    @Test func aPhotoHashThatIsNotOneKeepsThePhotoShown() throws {
        let fixture = EngineFixture(alice)
        fixture.stores.blobs.insert(jpeg, hash: BlobHash(of: jpeg), mime: "image/jpeg", storedAt: 1)
        fixture.deliver(try profile(of: bob, photo: jpeg, version: 5, from: fixture), from: bob)
        let malformed = try bob.profile(version: 6, publishedAt: fixture.clock.wallMilliseconds() + 6, avatarHash: "av1")
        fixture.deliver(malformed, from: bob)
        let record = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(record.avatarHash == BlobHash(of: jpeg) && record.advertisedAvatarHash == nil)
    }

    // MARK: Collecting

    @Test func aStartRemovesEveryBlobNothingNames() {
        let stores = MeshStores.inMemory()
        let named = BlobHash(of: jpeg)
        let orphan = BlobHash(of: newer)
        stores.blobs.insert(jpeg, hash: named, mime: "image/jpeg", storedAt: 1)
        stores.blobs.insert(newer, hash: orphan, mime: "image/jpeg", storedAt: 1)
        var own = stores.ownProfile.load()
        own.avatarHash = named
        stores.ownProfile.save(own)
        _ = EngineFixture(alice, stores: stores)
        #expect(stores.blobs.allHashes() == [named])
    }

    @Test func aStartAsksForEveryAdvertisedPhotoStillMissing() {
        let stores = MeshStores.inMemory()
        stores.peers.upsert(
            PeerRecord(
                nodeId: bob.nodeId,
                name: "Bob",
                status: "",
                publicKey: bob.keys.bundle.encoded,
                updatedAt: 1,
                advertisedAvatarHash: BlobHash(of: jpeg)
            ))
        let fixture = EngineFixture(alice, stores: stores)
        #expect(fixture.engine.blobExchange.isWanted(BlobHash(of: jpeg)))
        fixture.link(carol)
        #expect(fixture.transport.written(.blobRequest).map(\.to) == [carol.nodeId])
    }

    @Test func aPhotoNamedButNotHeldIsNotPushed() {
        let stores = MeshStores.inMemory()
        var own = stores.ownProfile.load()
        own.avatarHash = BlobHash(of: jpeg)
        stores.ownProfile.save(own)
        let fixture = EngineFixture(alice, stores: stores)
        fixture.link(bob)
        #expect(fixture.transport.files.isEmpty)
    }

    @Test func aPhotoAProfileNamesIsKeptEvenOnceNobodyWantsItAnyMore() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        fixture.deliver(try profile(of: bob, photo: jpeg, version: 5, from: fixture), from: carol)
        // The want aged out while the bytes were on their way; the profile still names them.
        fixture.engine.blobExchange.forget(BlobHash(of: jpeg))
        fixture.engine.receiveFile(
            InboundFile(from: carol.nodeId, kind: .attachment, hash: BlobHash(of: jpeg), mime: "image/jpeg", bytes: jpeg))
        #expect(fixture.stores.peers.peer(bob.nodeId)?.avatarHash == BlobHash(of: jpeg))
    }

    @Test func aPhotoTwoPeersShareStaysWhenOneClearsIt() throws {
        let fixture = EngineFixture(alice)
        fixture.stores.blobs.insert(jpeg, hash: BlobHash(of: jpeg), mime: "image/jpeg", storedAt: 1)
        fixture.deliver(try profile(of: bob, photo: jpeg, version: 5, from: fixture), from: bob)
        fixture.deliver(try profile(of: carol, photo: jpeg, version: 5, from: fixture), from: carol)
        fixture.deliver(try profile(of: bob, photo: nil, version: 6, from: fixture), from: bob)
        #expect(fixture.stores.blobs.contains(BlobHash(of: jpeg)), "carol's photo still")
        #expect(fixture.stores.peers.peer(carol.nodeId)?.avatarHash == BlobHash(of: jpeg))
    }
}
