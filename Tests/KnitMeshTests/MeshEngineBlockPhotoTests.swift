import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A block hides a person's photo, and an unblock shows it again (knit-ios #37, knit-next #249, the paired change
/// `block-hides-profile` at contract revision 1; ADR 2026-10.5wgg). While they are blocked their face is their initial,
/// their photo is neither wanted, taken from their push nor shown, and their row names no blob, so the sweep takes the
/// bytes. An unblock re-applies the profile kept for them and follows the photo their row kept.
@Suite struct MeshEngineBlockPhotoTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private let start = EngineFixture.start

    private let face: [UInt8] = Array("bob's face".utf8)
    private let newer: [UInt8] = Array("bob's newer face".utf8)
    private var faceHash: BlobHash { BlobHash(of: face) }
    private var newerHash: BlobHash { BlobHash(of: newer) }
    /// What a build that reads a `blobcancel` claims in its HELLO.
    private let android = Capabilities.local.union(.blobHave)

    private func profile(
        of peer: TestPeer, name: String = "Bob", photo: BlobHash?, version: Int64, tag: String? = nil
    ) throws -> TestFrame {
        try peer.profile(name: name, version: version, publishedAt: start + version, avatarHash: photo?.string, deviceTag: tag)
    }

    private func hold(_ bytes: [UInt8], in fixture: EngineFixture) {
        #expect(fixture.stores.blobs.insert(bytes, hash: BlobHash(of: bytes), mime: "image/jpeg", storedAt: start))
    }

    private func asked(_ fixture: EngineFixture, for hash: BlobHash) throws -> [NodeId?] {
        try fixture.transport.written(.blobRequest).filter { try BlobRequestContent(decoding: $0.envelope.payload).hash == hash.string }
            .map(\.to)
    }

    private func cancelled(_ fixture: EngineFixture, for hash: BlobHash) throws -> [NodeId?] {
        try fixture.transport.written(.blobCancel).filter { try BlobCancelContent(decoding: $0.envelope.payload).hash == hash.string }
            .map(\.to)
    }

    /// Carol's room post naming `hash`, so a message row names it.
    private func roomPhoto(_ hash: BlobHash, in fixture: EngineFixture) throws {
        let post = ChatContent(body: "Look", attachmentHash: hash.string, attachmentMime: "image/jpeg")
        fixture.deliver(
            try carol.roomPost("Look", id: frameIdOf("post-\(hash.string.prefix(8))"), sentAt: start, content: post), from: carol)
    }

    private func sweepPastTheCutoff(_ fixture: EngineFixture) {
        let sweeps = BlobExchange.wantMilliseconds / fixture.engine.configuration.sweepMilliseconds + 1
        for _ in 0...sweeps {
            fixture.advance(fixture.engine.configuration.sweepMilliseconds)
        }
    }

    // MARK: Taking in

    @Test func aPushFromABlockedLinkIsRefusedAndNotKept() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.deliver(try profile(of: bob, photo: faceHash, version: 5), from: bob)
        fixture.engine.block(bob.nodeId)
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .avatar, hash: faceHash, mime: "image/jpeg", bytes: face))
        #expect(!fixture.stores.blobs.contains(faceHash))
        #expect(fixture.engine.filesRejected == 1)
        #expect(fixture.log.all.contains { $0.contains("from \(bob.nodeId) is from someone blocked; dropped") })
        #expect(fixture.stores.peers.peer(bob.nodeId)?.avatarHash == nil)
    }

    @Test func aBlockedLinksPushIsKeptWhenWantedOrNamedButNeverShown() throws {
        // Wanted as an attachment.
        let wanted = EngineFixture(alice)
        wanted.link(bob)
        wanted.deliver(try profile(of: bob, photo: faceHash, version: 5), from: bob)
        wanted.engine.block(bob.nodeId)
        wanted.engine.wantBlob(faceHash, author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: false))
        wanted.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .avatar, hash: faceHash, mime: "image/jpeg", bytes: face))
        #expect(wanted.stores.blobs.contains(faceHash) && wanted.engine.filesRejected == 0)
        #expect(wanted.stores.peers.peer(bob.nodeId)?.avatarHash == nil, "kept, and still not their face")

        // Named by a message row, and no longer wanted.
        let named = EngineFixture(alice)
        named.link(bob, carol)
        try named.pin(carol)
        named.deliver(try profile(of: bob, photo: faceHash, version: 5), from: bob)
        named.engine.block(bob.nodeId)
        try roomPhoto(faceHash, in: named)
        named.engine.blobExchange.forget(faceHash)
        named.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .avatar, hash: faceHash, mime: "image/jpeg", bytes: face))
        #expect(named.stores.blobs.contains(faceHash) && named.engine.filesRejected == 0)
        #expect(named.stores.peers.peer(bob.nodeId)?.avatarHash == nil)
    }

    @Test func aPhotoWantedBeforeTheBlockIsNotShownWhenItLandsAfter() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol, capabilities: android)
        fixture.deliver(try profile(of: bob, photo: faceHash, version: 5), from: carol)
        #expect(try asked(fixture, for: faceHash) == [carol.nodeId])
        // On its way when the block comes, so the want stands and the copy lands.
        fixture.transport.arrivingFileKeys = [faceHash]
        fixture.engine.block(bob.nodeId)
        #expect(fixture.engine.blobExchange.isWanted(faceHash))
        fixture.transport.arrivingFileKeys = []
        _ = fixture.engine.drainEvents()
        fixture.engine.receiveFile(InboundFile(from: carol.nodeId, kind: .attachment, hash: faceHash, mime: "image/jpeg", bytes: face))
        #expect(fixture.stores.blobs.contains(faceHash))
        #expect(fixture.stores.peers.peer(bob.nodeId)?.avatarHash == nil)
        #expect(fixture.engine.drainEvents().isEmpty)
    }

    @Test func aWantSparedAsArrivingIsWithdrawnOnceItIsNoLongerOnItsWay() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol, capabilities: android)
        fixture.deliver(try profile(of: bob, photo: faceHash, version: 5), from: carol)
        #expect(try asked(fixture, for: faceHash) == [carol.nodeId])
        fixture.transport.arrivingFileKeys = [faceHash]
        fixture.engine.block(bob.nodeId)
        #expect(fixture.engine.blobExchange.isWanted(faceHash) && fixture.transport.written(.blobCancel).isEmpty)
        // The copy never landed: the next re-offer's re-want withdraws the want.
        fixture.transport.arrivingFileKeys = []
        fixture.advance(60_000)
        #expect(!fixture.engine.blobExchange.isWanted(faceHash))
        #expect(try cancelled(fixture, for: faceHash) == [carol.nodeId])
    }

    @Test func aWantPulledForANeighbourStandsUntilItHasNoPullerLeft() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol, dave, capabilities: android)
        fixture.deliver(try profile(of: bob, photo: faceHash, version: 5), from: carol)
        #expect(fixture.engine.blobExchange.wants[faceHash]?.origin == .own)
        fixture.deliver(dave.blobRequest(for: faceHash.string, id: frameIdOf("breq-dave")), from: dave)
        #expect(fixture.engine.blobExchange.wants[faceHash]?.pullers == [dave.nodeId])
        fixture.engine.block(bob.nodeId)
        #expect(fixture.engine.blobExchange.isWanted(faceHash), "Dave waits for the copy")
        #expect(fixture.transport.written(.blobCancel).isEmpty)
        // Dave no longer waits: the next re-offer's re-want withdraws it.
        fixture.engine.blobExchange.wants[faceHash]?.pullers.removeAll()
        fixture.advance(60_000)
        #expect(!fixture.engine.blobExchange.isWanted(faceHash))
        #expect(fixture.transport.written(.blobCancel).count == 1)
    }

    // MARK: On block

    @Test func aBlockClearsTheFaceKeepsTheAdvertisedPhotoAndWithdrawsItsWant() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol, capabilities: android)
        hold(face, in: fixture)
        fixture.deliver(try profile(of: bob, photo: faceHash, version: 5), from: carol)
        fixture.deliver(try profile(of: bob, photo: newerHash, version: 6), from: carol)
        #expect(try asked(fixture, for: newerHash) == [carol.nodeId])
        #expect(fixture.engine.blobExchange.isPhotoOnly(newerHash))
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()

        fixture.engine.block(bob.nodeId)
        let row = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(row.avatarHash == nil && row.advertisedAvatarHash == newerHash)
        #expect(fixture.engine.drainEvents() == [.peerUpdated(bob.nodeId)])
        #expect(!fixture.engine.blobExchange.isWanted(newerHash))
        #expect(try cancelled(fixture, for: newerHash) == [carol.nodeId], "the holder asked drops a copy it queued")
        #expect(fixture.stores.blobs.contains(faceHash), "never let go here: the sweep takes it")

        fixture.engine.block(bob.nodeId)
        #expect(fixture.engine.drainEvents().isEmpty, "a row with no face is left alone")
    }

    @Test func aBlockLeavesAWantAnotherUnblockedRowOrAnAttachmentHolds() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol, capabilities: android)
        try fixture.pin(carol)
        fixture.deliver(try profile(of: bob, photo: newerHash, version: 5), from: carol)
        fixture.deliver(try profile(of: dave, name: "Dave", photo: newerHash, version: 5), from: carol)
        #expect(fixture.engine.blobExchange.isPhotoOnly(newerHash))
        fixture.engine.block(bob.nodeId)
        #expect(fixture.engine.blobExchange.isWanted(newerHash), "Dave's photo too")

        let attachment = EngineFixture(alice)
        attachment.link(carol, capabilities: android)
        try attachment.pin(carol)
        attachment.deliver(try profile(of: bob, photo: faceHash, version: 5), from: carol)
        try roomPhoto(faceHash, in: attachment)
        #expect(!attachment.engine.blobExchange.isPhotoOnly(faceHash))
        attachment.engine.block(bob.nodeId)
        #expect(attachment.engine.blobExchange.isWanted(faceHash), "a message's photo too")
        #expect(attachment.transport.written(.blobCancel).isEmpty)
    }

    @Test func theSweepTakesABlockedFaceUnlessSomethingElseNamesIt() throws {
        func blocked(_ also: ((EngineFixture) throws -> Void)? = nil) throws -> EngineFixture {
            let fixture = EngineFixture(alice)
            fixture.link(carol)
            try fixture.pin(carol)
            hold(face, in: fixture)
            fixture.deliver(try profile(of: bob, photo: faceHash, version: 5), from: carol)
            try also?(fixture)
            fixture.engine.block(bob.nodeId)
            sweepPastTheCutoff(fixture)
            return fixture
        }
        let alone = try blocked()
        #expect(!alone.stores.blobs.contains(faceHash))
        _ = alone.engine.drainEvents()
        alone.advance(alone.engine.configuration.sweepMilliseconds)
        #expect(alone.engine.drainEvents().isEmpty, "a second sweep hides nothing more")

        let posted = try blocked { try roomPhoto(faceHash, in: $0) }
        #expect(posted.stores.blobs.contains(faceHash), "a message row names it")
        let shared = try blocked { $0.deliver(try profile(of: dave, name: "Dave", photo: faceHash, version: 5), from: carol) }
        #expect(shared.stores.blobs.contains(faceHash), "Dave's row names it")
        #expect(shared.stores.peers.peer(dave.nodeId)?.avatarHash == faceHash)
    }

    @Test func theSweepHidesTheFaceOfABlockWrittenPastTheEngine() throws {
        let fixture = EngineFixture(alice)
        hold(face, in: fixture)
        fixture.deliver(try profile(of: bob, photo: faceHash, version: 5), from: bob)
        fixture.stores.blocks.block(bob.nodeId, deviceTag: nil)
        _ = fixture.engine.drainEvents()
        fixture.advance(fixture.engine.configuration.sweepMilliseconds)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.avatarHash == nil)
        #expect(fixture.engine.drainEvents() == [.peerUpdated(bob.nodeId)])
    }

    @Test func aBlockThatFollowsNewKeysClearsTheFaceAtOnce() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        let rekeyed = TestPeer(seed: 5)
        hold(face, in: fixture)
        fixture.deliver(try profile(of: bob, photo: nil, version: 5, tag: "a1b2c3d4e5f60718"), from: carol)
        fixture.deliver(try profile(of: rekeyed, photo: faceHash, version: 5, tag: "0f0e0d0c0b0a0908"), from: carol)
        #expect(fixture.stores.peers.peer(rekeyed.nodeId)?.avatarHash == faceHash)
        fixture.engine.block(bob.nodeId)
        _ = fixture.engine.drainEvents()
        fixture.deliver(try profile(of: rekeyed, photo: faceHash, version: 6, tag: "a1b2c3d4e5f60718"), from: carol)
        #expect(fixture.engine.isBlocked(rekeyed.nodeId))
        let row = try #require(fixture.stores.peers.peer(rekeyed.nodeId))
        #expect(row.avatarHash == nil && row.advertisedAvatarHash == faceHash)
        #expect(fixture.engine.drainEvents().contains(.peerUpdated(rekeyed.nodeId)))
    }

    @Test func aBlockedRowsPhotoIsNotWantedAgain() {
        let stores = MeshStores.inMemory()
        stores.peers.upsert(
            PeerRecord(
                nodeId: bob.nodeId,
                name: "Bob",
                status: "",
                publicKey: bob.keys.bundle.encoded,
                updatedAt: 1,
                advertisedAvatarHash: faceHash
            ))
        stores.blocks.block(bob.nodeId, deviceTag: nil)
        let fixture = EngineFixture(alice, stores: stores)
        #expect(!fixture.engine.blobExchange.isWanted(faceHash))
        fixture.link(carol)
        fixture.advance(60_000)
        #expect(fixture.transport.written(.blobRequest).isEmpty)
    }
}
