import KnitCrypto
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The edges of a block's hold on a photo (knit-ios #37; ADR 2026-11.y793), beside ``MeshEngineBlockPhotoTests``: a block
/// by the row's tag alone, a withdrawal inside someone else's unit, a follow of a blocked sender's photo, and a contact
/// link whose read after the unblock fails.
@Suite struct MeshEngineBlockPhotoEdgeTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private let start = EngineFixture.start
    private let tag = "a1b2c3d4e5f60718"

    private let face: [UInt8] = Array("bob's face".utf8)
    private var faceHash: BlobHash { BlobHash(of: face) }
    private let android = Capabilities.local.union(.blobHave)

    private func profile(name: String = "Bob", photo: BlobHash?, version: Int64, tag: String? = nil) throws -> TestFrame {
        try bob.profile(name: name, version: version, publishedAt: start + version, avatarHash: photo?.string, deviceTag: tag)
    }

    @Test func anUnblockOfSomeoneBlockedByTheirTagAloneShowsTheirFaceAgain() throws {
        let fixture = EngineFixture(alice)
        #expect(fixture.stores.blobs.insert(face, hash: faceHash, mime: "image/jpeg", storedAt: start))
        fixture.deliver(try profile(photo: faceHash, version: 5, tag: tag), from: bob)
        // The tag blocked under another id, and Bob's face hidden, as a block of his old keys left them.
        fixture.stores.blocks.block(dave.nodeId, deviceTag: tag)
        var hidden = try #require(fixture.stores.peers.peer(bob.nodeId))
        hidden.avatarHash = nil
        fixture.stores.peers.upsert(hidden)
        #expect(!fixture.engine.isBlocked(bob.nodeId))
        _ = fixture.engine.drainEvents()
        fixture.engine.unblock(bob.nodeId)
        #expect(!fixture.stores.blocks.isBlocked(deviceTag: tag))
        #expect(fixture.stores.peers.peer(bob.nodeId)?.avatarHash == faceHash)
        #expect(fixture.engine.drainEvents() == [.peerUpdated(bob.nodeId)])
    }

    @Test func aWithdrawalInsideAnotherUnitWithdrawsNothing() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol, capabilities: android)
        fixture.deliver(try profile(photo: faceHash, version: 5), from: carol)
        #expect(fixture.engine.blobExchange.isPhotoOnly(faceHash))
        fixture.stores.blocks.block(bob.nodeId, deviceTag: nil)
        fixture.transport.clear()
        let unit = fixture.stores.transactor.atomically { () -> Void? in
            fixture.engine.withdrawBlockedPhotos()
            return ()
        }
        guard case .committed = unit else {
            Issue.record("the outer unit did not commit")
            return
        }
        #expect(fixture.engine.blobExchange.isWanted(faceHash), "only joined, so nothing is withdrawn")
        #expect(fixture.transport.written(.blobCancel).isEmpty)
        fixture.engine.withdrawBlockedPhotos()
        #expect(!fixture.engine.blobExchange.isWanted(faceHash), "in a unit of its own, it is")
        #expect(fixture.transport.written(.blobCancel).map(\.to) == [carol.nodeId])
    }

    @Test func aBlockedSendersPhotoIsNeverFollowed() {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        fixture.engine.block(bob.nodeId)
        fixture.transport.clear()
        fixture.engine.followAdvertisedPhoto(faceHash, of: bob.nodeId, askingLinked: true)
        #expect(!fixture.engine.blobExchange.isWanted(faceHash))
        #expect(fixture.transport.written(.blobRequest).isEmpty)
    }

    @Test func aContactLinkWhoseReadAfterTheUnblockFailsKeepsTheRowItHeld() throws {
        let stores = MeshStores.inMemory()
        let reads = FailingNthPeerRead(stores.peers)
        let fixture = EngineFixture(alice, stores: stores.replacing(peers: reads))
        fixture.deliver(try profile(photo: nil, version: 5), from: carol)
        fixture.engine.block(bob.nodeId)
        fixture.deliver(try profile(name: "Robert", photo: nil, version: 6), from: carol)
        let links = try #require(ContactCard.encode(bob.keys, name: "Card name", issuedAt: start))
        let card = try #require(ContactCard.parse(links.url).card)
        // `addContact`'s reads: the row held, the unblock's tag, the re-apply's row, the face's row, and then the row
        // again after the unblock, which fails.
        reads.failing = reads.count + 5
        #expect(fixture.engine.addContact(card, from: .link, unblock: true) == .added(bob.nodeId))
        #expect(reads.failed)
        let row = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(row.name == "Robert" && row.updatedAt == 6, "the row the unblock left, never a fresh one")
        #expect(fixture.stores.blocks.blockedNodeIds().isEmpty)
    }
}

/// A peer store whose one row read numbered ``failing`` answers `nil`, as a database that cannot read its file does
/// outside a unit (``FailingPeerReads`` fails the next few instead).
private final class FailingNthPeerRead: PeerStore {
    private struct State {
        var count = 0
        var failing = 0
        var failed = false
    }

    private let held: any PeerStore
    private let state = Lock(State())

    init(_ held: any PeerStore) {
        self.held = held
    }

    /// How many row reads were made.
    var count: Int { state.withLock { $0.count } }
    /// The number of the read that fails.
    var failing: Int {
        get { state.withLock { $0.failing } }
        set { state.withLock { $0.failing = newValue } }
    }
    /// Whether it failed.
    var failed: Bool { state.withLock { $0.failed } }

    func peer(_ nodeId: NodeId) -> PeerRecord? {
        let fails = state.withLock { state -> Bool in
            state.count += 1
            guard state.count == state.failing else {
                return false
            }
            state.failed = true
            return true
        }
        return fails ? nil : held.peer(nodeId)
    }

    func upsert(_ peer: PeerRecord) { held.upsert(peer) }
    func verifiedNodeIds() -> Set<NodeId> { held.verifiedNodeIds() }
    func allPeers() -> [PeerRecord] { held.allPeers() }
    func recordProfileFrame(_ frame: WireEnvelope, of nodeId: NodeId, sentAt: Int64) {
        held.recordProfileFrame(frame, of: nodeId, sentAt: sentAt)
    }
    func profileFrame(of nodeId: NodeId) -> WireEnvelope? { held.profileFrame(of: nodeId) }
    func deleteProfileFrames(longerThan maxSignedBytes: Int) -> Int { held.deleteProfileFrames(longerThan: maxSignedBytes) }
}
