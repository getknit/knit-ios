import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The unblock's face restore holds until the row shows the photo, a newer profile takes over, or the person is blocked
/// again (contract revision 2 of `block-hides-profile`, knit-ios #37; ADR 2026-11.y793). No memo carries it: the want is
/// derived from the row at every start and 60 s re-offer (``MeshEngine/rewantMissingBlobs(sparing:)``), which spares a
/// linked person only at link-up, so it outlives a lapsed want, a restart and an unblock made while the mesh was stopped.
/// A linked person never pushes the photo again, since their push memo holds the hash.
@Suite struct MeshEngineUnblockFaceTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let start = EngineFixture.start

    private let face: [UInt8] = Array("bob's face".utf8)
    private let newer: [UInt8] = Array("bob's newer face".utf8)
    private var faceHash: BlobHash { BlobHash(of: face) }
    private var newerHash: BlobHash { BlobHash(of: newer) }

    private func profile(name: String = "Bob", photo: BlobHash?, version: Int64) throws -> TestFrame {
        try bob.profile(name: name, version: version, publishedAt: start + version, avatarHash: photo?.string)
    }

    private func asked(_ fixture: EngineFixture, for hash: BlobHash) throws -> [NodeId?] {
        try fixture.transport.written(.blobRequest).filter { try BlobRequestContent(decoding: $0.envelope.payload).hash == hash.string }
            .map(\.to)
    }

    /// Alice, linked to Bob, whose photo she never held, just unblocked him and asked him for it once.
    private func unblocked() throws -> EngineFixture {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.deliver(try profile(photo: faceHash, version: 5), from: bob)
        fixture.engine.block(bob.nodeId)
        fixture.transport.clear()
        fixture.engine.unblock(bob.nodeId)
        #expect(try asked(fixture, for: faceHash) == [bob.nodeId])
        fixture.transport.clear()
        return fixture
    }

    /// Re-offers past the want's life and the sweep after it, which forgets a want made no more.
    private func pastTheWantsLife(_ fixture: EngineFixture) {
        reoffers(Int((BlobExchange.wantMilliseconds + fixture.engine.configuration.sweepMilliseconds) / 60_000) + 1, fixture)
    }

    private func reoffers(_ count: Int, _ fixture: EngineFixture) {
        for _ in 0..<count {
            fixture.advance(60_000)
        }
    }

    // MARK: Holds

    @Test func aWantThatLapsesIsMadeAgainFromTheRow() throws {
        let fixture = try unblocked()
        // No answer. Each re-offer's re-want refreshes the want, so it outlives its life while the row names the photo.
        pastTheWantsLife(fixture)
        #expect(fixture.engine.blobExchange.isWanted(faceHash))
        // Lapsed all the same, as a want the re-offer missed would: the next re-offer makes it again from the row.
        #expect(fixture.engine.blobExchange.sweep(now: fixture.clock.monotonicMilliseconds() + BlobExchange.wantMilliseconds + 1) == 1)
        #expect(!fixture.engine.blobExchange.isWanted(faceHash))
        fixture.transport.clear()
        fixture.advance(60_000)
        #expect(try asked(fixture, for: faceHash) == [bob.nodeId], "asked of Bob again, though linked")
        #expect(fixture.engine.blobExchange.isWanted(faceHash))
        #expect(fixture.stores.peers.peer(bob.nodeId)?.advertisedAvatarHash == faceHash)
    }

    @Test func aRestartWantsItAgainOfTheLinkedPerson() throws {
        let before = try unblocked()
        let restarted = EngineFixture(alice, stores: before.stores)
        #expect(restarted.engine.blobExchange.isWanted(faceHash), "the start's re-want")
        restarted.link(bob)
        restarted.transport.clear()
        restarted.advance(60_000)
        #expect(try asked(restarted, for: faceHash) == [bob.nodeId], "the re-offer spares nobody")
    }

    @Test func anUnblockBeforeTheStartReappliesAtOnceAndWantsThePhotoOnceStarted() throws {
        let earlier = EngineFixture(alice)
        earlier.deliver(try profile(photo: nil, version: 5), from: bob)
        earlier.engine.block(bob.nodeId)
        earlier.deliver(try profile(name: "Robert", photo: faceHash, version: 6), from: bob)
        let stopped = EngineFixture(alice, stores: earlier.stores, started: false)
        stopped.engine.unblock(bob.nodeId)
        let row = try #require(stopped.stores.peers.peer(bob.nodeId))
        #expect(row.name == "Robert" && row.advertisedAvatarHash == faceHash)
        stopped.engine.start()
        stopped.link(bob)
        stopped.transport.clear()
        stopped.advance(60_000)
        #expect(try asked(stopped, for: faceHash) == [bob.nodeId])
    }

    // MARK: Ends

    @Test func itEndsOnceTheFaceShows() throws {
        let fixture = try unblocked()
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: faceHash, mime: "image/jpeg", bytes: face))
        #expect(fixture.stores.peers.peer(bob.nodeId)?.avatarHash == faceHash)
        fixture.transport.clear()
        reoffers(3, fixture)
        #expect(fixture.transport.written(.blobRequest).isEmpty)
        #expect(!fixture.engine.blobExchange.isWanted(faceHash))
    }

    @Test func itEndsWhenANewerProfileTakesOver() throws {
        let fixture = try unblocked()
        fixture.deliver(try profile(photo: newerHash, version: 6), from: bob)
        // The want of the old photo is no longer made again, and lapses; the new one is asked for.
        pastTheWantsLife(fixture)
        #expect(!fixture.engine.blobExchange.isWanted(faceHash))
        #expect(fixture.engine.blobExchange.isWanted(newerHash))
        fixture.transport.clear()
        reoffers(5, fixture)
        #expect(try asked(fixture, for: faceHash).isEmpty)
        #expect(try asked(fixture, for: newerHash).contains(bob.nodeId))
    }

    @Test func itEndsWhenTheyAreBlockedAgain() throws {
        let fixture = try unblocked()
        fixture.engine.block(bob.nodeId)
        #expect(!fixture.engine.blobExchange.isWanted(faceHash))
        pastTheWantsLife(fixture)
        #expect(fixture.transport.written(.blobRequest).isEmpty)
        #expect(!fixture.engine.blobExchange.isWanted(faceHash))
    }
}
