import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// An unblock shows a person's profile and photo again (knit-ios #37, the paired change `block-hides-profile` at contract
/// revision 1; ADR 2026-10.5wgg): the profile kept for them is re-applied when it is not older than the row
/// (``MeshEngine/reapplyHeldProfile(of:)``), and the photo the row kept is shown at once when held, or asked for of anyone
/// who has it, the person included, beside ``MeshEngineBlockPhotoTests``.
@Suite struct MeshEngineUnblockPhotoTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let start = EngineFixture.start

    private let face: [UInt8] = Array("bob's face".utf8)
    private let newer: [UInt8] = Array("bob's newer face".utf8)
    private var faceHash: BlobHash { BlobHash(of: face) }
    private var newerHash: BlobHash { BlobHash(of: newer) }

    private func profile(
        of peer: TestPeer, name: String = "Bob", photo: BlobHash?, version: Int64
    ) throws -> TestFrame {
        try peer.profile(name: name, version: version, publishedAt: start + version, avatarHash: photo?.string)
    }

    private func hold(_ bytes: [UInt8], in fixture: EngineFixture) {
        #expect(fixture.stores.blobs.insert(bytes, hash: BlobHash(of: bytes), mime: "image/jpeg", storedAt: start))
    }

    private func asked(_ fixture: EngineFixture, for hash: BlobHash) throws -> [NodeId?] {
        try fixture.transport.written(.blobRequest).filter { try BlobRequestContent(decoding: $0.envelope.payload).hash == hash.string }
            .map(\.to)
    }

    @Test func anUnblockReappliesTheKeptProfileAndAsksALinkedPeerForItsPhoto() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.deliver(try profile(of: bob, photo: nil, version: 5), from: bob)
        fixture.engine.block(bob.nodeId)
        fixture.deliver(try profile(of: bob, name: "Robert", photo: faceHash, version: 6), from: bob)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.name == "Bob")
        fixture.transport.clear()
        fixture.engine.unblock(bob.nodeId)
        let row = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(row.name == "Robert" && row.advertisedAvatarHash == faceHash && row.avatarHash == nil)
        #expect(try asked(fixture, for: faceHash) == [bob.nodeId], "asked of him, though linked, as no push is owed")
        #expect(fixture.engine.blobExchange.isPhotoOnly(faceHash))
    }

    @Test func anUnblockWantsThePhotoTheRowShowsWhenItsBytesAreGone() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        var row = PeerRecord(nodeId: bob.nodeId, name: "Bob", status: "", publicKey: bob.keys.bundle.encoded, updatedAt: 1)
        row.advertisedAvatarHash = faceHash
        row.avatarHash = faceHash
        fixture.stores.peers.upsert(row)
        fixture.stores.blocks.block(bob.nodeId, deviceTag: nil)
        fixture.transport.clear()
        fixture.engine.unblock(bob.nodeId)
        #expect(try asked(fixture, for: faceHash) == [bob.nodeId])
    }

    @Test func anUnblockShowsTheKeptPhotoAtOnceWithNoFrameOrAStaleOne() throws {
        // No frame kept: a row a card made, with a photo it was given.
        let bare = EngineFixture(alice)
        bare.link(bob)
        hold(face, in: bare)
        var row = PeerRecord(nodeId: bob.nodeId, name: "Bob", status: "here", publicKey: bob.keys.bundle.encoded, updatedAt: 1)
        row.advertisedAvatarHash = faceHash
        row.avatarHash = faceHash
        bare.stores.peers.upsert(row)
        bare.engine.block(bob.nodeId)
        #expect(bare.stores.peers.peer(bob.nodeId)?.avatarHash == nil)
        _ = bare.engine.drainEvents()
        bare.transport.clear()
        bare.engine.unblock(bob.nodeId)
        #expect(bare.stores.peers.peer(bob.nodeId) == row, "the face back, and the name and status as they were")
        #expect(bare.engine.drainEvents() == [.peerUpdated(bob.nodeId)])
        #expect(bare.transport.written(.blobRequest).isEmpty)

        // A stale frame: a sealed profile raised the watermark past it before the block.
        let stale = EngineFixture(alice)
        stale.link(bob)
        hold(face, in: stale)
        stale.deliver(try profile(of: bob, photo: faceHash, version: 5), from: bob)
        stale.engine.block(bob.nodeId)
        stale.deliver(try profile(of: bob, name: "Robert", photo: newerHash, version: 6), from: bob)
        var raised = try #require(stale.stores.peers.peer(bob.nodeId))
        raised.updatedAt = 7
        stale.stores.peers.upsert(raised)
        stale.transport.clear()
        stale.engine.unblock(bob.nodeId)
        let after = try #require(stale.stores.peers.peer(bob.nodeId))
        #expect(after.name == "Bob" && after.avatarHash == faceHash && after.advertisedAvatarHash == faceHash)
        #expect(stale.transport.written(.blobRequest).isEmpty)
    }

    @Test func aQuickBlockAndUnblockShowsTheHeldPhotoWithNoAsk() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        hold(face, in: fixture)
        fixture.deliver(try profile(of: bob, photo: faceHash, version: 5), from: carol)
        fixture.engine.block(bob.nodeId)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        fixture.engine.unblock(bob.nodeId)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.avatarHash == faceHash)
        #expect(fixture.engine.drainEvents() == [.peerUpdated(bob.nodeId)])
        #expect(fixture.transport.written(.blobRequest).isEmpty)
    }

    @Test func anUnblockAsksForNoPhotoRefusedThisSession() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        fixture.deliver(try profile(of: bob, photo: faceHash, version: 5), from: carol)
        fixture.engine.block(bob.nodeId)
        fixture.engine.blobExchange.refusePhoto(faceHash)
        fixture.transport.clear()
        fixture.engine.unblock(bob.nodeId)
        #expect(!fixture.engine.blobExchange.isWanted(faceHash))
        #expect(fixture.transport.written(.blobRequest).isEmpty)
    }

    @Test func anUnblockOfNobodyBlockedMovesNothing() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        fixture.deliver(try profile(of: bob, photo: faceHash, version: 5), from: carol)
        _ = fixture.engine.drainEvents()
        fixture.engine.blobExchange.forget(faceHash)
        fixture.transport.clear()
        fixture.engine.unblock(bob.nodeId)
        #expect(!fixture.engine.blobExchange.isWanted(faceHash))
        #expect(fixture.engine.drainEvents().isEmpty)
    }

    @Test func aContactLinkThatUnblocksKeepsTheReappliedName() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        fixture.deliver(try profile(of: bob, photo: nil, version: 5), from: carol)
        fixture.engine.block(bob.nodeId)
        fixture.deliver(try profile(of: bob, name: "Robert", photo: nil, version: 6), from: carol)
        let links = try #require(ContactCard.encode(bob.keys, name: "Card name", issuedAt: start))
        let card = try #require(ContactCard.parse(links.url).card)
        #expect(fixture.engine.addContact(card, from: .link, unblock: true) == .added(bob.nodeId))
        #expect(fixture.stores.peers.peer(bob.nodeId)?.name == "Robert")
    }

    // MARK: Both sides

    @Test func aPhotoRefusedDuringTheBlockIsAskedOfItsOwnerAfterAndServedOnce() throws {
        // Bob pushes his photo to Alice while she has him blocked; she refuses it. Once she unblocks him, she asks him for
        // it, and he serves one copy, which she shows.
        let lab = EngineLab([EngineFixture(alice), EngineFixture(bob, seed: 11)])
        let (ours, theirs) = (lab[0], lab[1])
        lab.link(0, 1)
        #expect(ours.stores.peers.peer(bob.nodeId) != nil)
        ours.engine.block(bob.nodeId)
        theirs.engine.setAvatar(face)
        lab.carry()
        let pushed = try #require(theirs.transport.files.first { $0.to == alice.nodeId })
        #expect(pushed.kind == .avatar)
        ours.engine.receiveFile(InboundFile(from: bob.nodeId, kind: pushed.kind, hash: pushed.hash, mime: pushed.mime, bytes: pushed.bytes))
        #expect(!ours.stores.blobs.contains(faceHash) && ours.engine.filesRejected == 1)

        let before = theirs.transport.files.count
        ours.engine.unblock(bob.nodeId)
        lab.carry()
        let served = theirs.transport.files.dropFirst(before).filter { $0.to == alice.nodeId && $0.hash == faceHash }
        #expect(served.count == 1 && served.first?.kind == .attachment, "one copy, served as asked")
        let copy = try #require(served.first)
        ours.engine.receiveFile(InboundFile(from: bob.nodeId, kind: copy.kind, hash: copy.hash, mime: copy.mime, bytes: copy.bytes))
        let row = try #require(ours.stores.peers.peer(bob.nodeId))
        #expect(row.avatarHash == faceHash && row.advertisedAvatarHash == faceHash)
    }
}
