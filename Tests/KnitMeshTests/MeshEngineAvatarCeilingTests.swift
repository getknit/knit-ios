import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The profile photo's ceiling through the engine (ADR 2026-10.r88m, contract `profile-door-cap` section 6), beside
/// ``MeshEngineAvatarTests``: a photo-only want keeps a holder's copy to 1 MiB, a holder past it is passed over for the
/// session, the author included, and a held photo past it is refused, never shown, and goes.
@Suite struct MeshEngineAvatarCeilingTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)

    /// Holder queries on, as they are wherever a `blobhas` can say a size.
    private static let querying = MeshConfiguration(queriesBlobHolders: true)
    /// What a build that reads the blob traffic claims in its HELLO.
    private let android = Capabilities.local.union(.blobHave)
    private let small: [UInt8] = Array("a 256-pixel JPEG, in spirit".utf8)
    private var smallHash: BlobHash { BlobHash(of: small) }
    private let tooLarge = Int64(FileIntake.maxAvatarBytes) * 2
    /// A held photo one byte past the ceiling.
    private let oversize = [UInt8](repeating: 0xD8, count: FileIntake.maxAvatarBytes + 1)

    private func profile(of peer: TestPeer, photo: BlobHash, version: Int64, from fixture: EngineFixture) throws -> TestFrame {
        try peer.profile(version: version, publishedAt: fixture.clock.wallMilliseconds() + version, avatarHash: photo.string)
    }

    /// The neighbours asked for `hash`, in order.
    private func asked(_ fixture: EngineFixture, for hash: BlobHash) throws -> [NodeId?] {
        try fixture.transport.written(.blobRequest).filter { try BlobRequestContent(decoding: $0.envelope.payload).hash == hash.string }
            .map(\.to)
    }

    /// The neighbours queried for `hash`, in order.
    private func queried(_ fixture: EngineFixture, for hash: BlobHash) throws -> [NodeId?] {
        try fixture.transport.written(.blobHave).filter { try BlobHaveContent(decoding: $0.envelope.payload).hashes.contains(hash.string) }
            .map(\.to)
    }

    /// `peer`'s answer that it holds `hash` at `size`, naming no query of ours, which is still taken from a neighbour
    /// queried this cycle; its id is its own, so the router never takes it for another's.
    private func has(_ peer: TestPeer, _ hash: BlobHash, size: Int64, load: Int = 0) -> TestFrame {
        peer.blobHas([BlobHasItem(hash: hash.string, state: .have, size: size)], re: "\(peer.nodeId)-\(size)", load: load)
    }

    /// Alice, with bob and carol linked and able to answer, wanting dave's photo `hash`: dave is not linked, so nobody
    /// pushes it, and his profile came from carol.
    private func wanting(_ hash: BlobHash) throws -> EngineFixture {
        let fixture = EngineFixture(alice, configuration: Self.querying)
        fixture.link(bob, carol, capabilities: android)
        fixture.deliver(try profile(of: dave, photo: hash, version: 5, from: fixture), from: carol)
        #expect(fixture.engine.blobExchange.isPhotoOnly(hash))
        #expect(fixture.transport.photoOnly == [hash], "the links keep it to the photo's ceiling")
        return fixture
    }

    // MARK: A holder that is not the author

    @Test func aHolderClaimingAnOversizePhotoIsNeverAskedAndTheOtherBringsIt() throws {
        let fixture = try wanting(smallHash)
        fixture.deliver(has(bob, smallHash, size: tooLarge), from: bob)
        #expect(try asked(fixture, for: smallHash).isEmpty)
        fixture.deliver(has(carol, smallHash, size: Int64(small.count)), from: carol)
        #expect(try asked(fixture, for: smallHash) == [carol.nodeId], "no blobreq to bob")
        fixture.engine.receiveFile(InboundFile(from: carol.nodeId, kind: .attachment, hash: smallHash, mime: "image/jpeg", bytes: small))
        #expect(fixture.stores.peers.peer(dave.nodeId)?.avatarHash == smallHash, "shown")
        #expect(fixture.engine.blobExchange.counts.photosOverCeiling == 1)
        let shown = smallHash.string.prefix(BlobExchange.shownHashCharacters)
        #expect(fixture.log.all.contains("debug mesh blob photo \(shown)… from \(bob.nodeId) claims \(tooLarge)B: passed over"))
    }

    @Test func aHolderStreamingPastTheCeilingIsAskedNoMoreThisSessionAndTheOtherIs() throws {
        let fixture = try wanting(smallHash)
        // Bob is the better holder, so he is asked first.
        fixture.deliver(has(bob, smallHash, size: Int64(small.count)), from: bob)
        fixture.deliver(has(carol, smallHash, size: Int64(small.count), load: 3), from: carol)
        #expect(try asked(fixture, for: smallHash) == [bob.nodeId])
        fixture.transport.clear()
        // His stream passes the ceiling: the link reports it, keeps nothing, and the want moves on to carol at once.
        fixture.engine.fileOverLimit(smallHash, from: bob.nodeId)
        #expect(!fixture.stores.blobs.contains(smallHash))
        #expect(try asked(fixture, for: smallHash) == [carol.nodeId])
        #expect(fixture.transport.written(.blobCancel).map(\.to) == [bob.nodeId], "a copy he queued and has not begun comes off")
        for _ in 0..<3 {
            fixture.advance(60_000)
        }
        #expect(try !asked(fixture, for: smallHash).contains(bob.nodeId), "at most once per holder per session")
        #expect(try !queried(fixture, for: smallHash).contains(bob.nodeId))
        #expect(fixture.engine.blobExchange.photoRefusals.isMarked(smallHash, holder: bob.nodeId))
    }

    @Test func aHolderPassedOverThatAsksForThePhotoIsNotAskedAgain() throws {
        // A neighbour's ask moves no ceiling (`BlobExchange.kt:116`, `:2211` at knit-next `a0b52f865`): bob, passed over
        // on his claim, cannot lift it by asking us for the hash.
        let fixture = try wanting(smallHash)
        fixture.deliver(has(bob, smallHash, size: tooLarge), from: bob)
        fixture.deliver(bob.blobRequest(for: smallHash.string, id: frameIdOf("breq-bob")), from: bob)
        #expect(fixture.engine.blobExchange.isPhotoOnly(smallHash))
        #expect(fixture.transport.photoOnly == [smallHash], "the links still keep it to the photo's ceiling")
        fixture.transport.clear()
        for _ in 0..<3 {
            fixture.advance(60_000)
        }
        #expect(try !asked(fixture, for: smallHash).contains(bob.nodeId))
        #expect(try !queried(fixture, for: smallHash).contains(bob.nodeId))
        #expect(try queried(fixture, for: smallHash).contains(carol.nodeId), "the want goes on with carol")
    }

    @Test func aRefusedPhotoWantLeavesAStandingEchoAtTheAttachmentsCeiling() {
        // `want` returns before `recordWant` for a refused photo (`BlobExchange.kt:289`), an echo standing or not.
        let fixture = EngineFixture(alice, configuration: Self.querying)
        fixture.link(bob, carol, capabilities: android)
        fixture.engine.blobExchange.refusePhoto(smallHash)
        fixture.deliver(carol.blobRequest(for: smallHash.string, id: frameIdOf("breq-carol")), from: carol)
        #expect(fixture.engine.blobExchange.isEcho(smallHash))
        let wanted = fixture.engine.wantBlob(
            smallHash, author: dave.nodeId, via: nil, asker: nil, reach: .own(until: nil, rederived: false), kind: .photo)
        #expect(!wanted)
        #expect(fixture.engine.blobExchange.isEcho(smallHash) && !fixture.engine.blobExchange.isPhotoOnly(smallHash))
        #expect(fixture.transport.photoOnly.isEmpty)
    }

    // MARK: The author

    @Test func theAuthorsOversizeClaimPassesHimOverLikeAnyHolder() throws {
        // Contract revision 5: dave is only whoever advertised the hash, so his claim refuses nothing outright. Dave is
        // linked: his own photo is left to his push, and wanted at the next re-offer when none came.
        let fixture = EngineFixture(alice, configuration: Self.querying)
        fixture.link(bob, dave, capabilities: android)
        fixture.deliver(try profile(of: dave, photo: smallHash, version: 5, from: fixture), from: dave)
        fixture.advance(60_000)
        #expect(fixture.engine.blobExchange.isPhotoOnly(smallHash))
        fixture.deliver(has(dave, smallHash, size: tooLarge), from: dave)
        fixture.deliver(has(bob, smallHash, size: Int64(small.count)), from: bob)
        #expect(try asked(fixture, for: smallHash) == [bob.nodeId], "the want goes on to bob")
        #expect(!fixture.engine.blobExchange.isPhotoRefused(smallHash))
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: smallHash, mime: "image/jpeg", bytes: small))
        #expect(fixture.stores.peers.peer(dave.nodeId)?.avatarHash == smallHash, "shown")
        #expect(try !asked(fixture, for: smallHash).contains(dave.nodeId))
    }

    @Test func aPeerAdvertisingAnotherPeersPhotoCannotHideIt() throws {
        // Carol signs a profile naming dave's photo and claims it is too large, or streams past the ceiling: she is passed
        // over, and bob, an honest holder, still brings dave's photo.
        for streams in [false, true] {
            let fixture = EngineFixture(alice, configuration: Self.querying)
            fixture.link(bob, carol, capabilities: android)
            fixture.deliver(try profile(of: dave, photo: smallHash, version: 5, from: fixture), from: bob)
            fixture.deliver(try profile(of: carol, photo: smallHash, version: 5, from: fixture), from: carol)
            if streams {
                fixture.deliver(has(carol, smallHash, size: Int64(small.count)), from: carol)
                fixture.deliver(has(bob, smallHash, size: Int64(small.count), load: 3), from: bob)
                #expect(try asked(fixture, for: smallHash) == [carol.nodeId])
                fixture.engine.fileOverLimit(smallHash, from: carol.nodeId)
            } else {
                fixture.deliver(has(carol, smallHash, size: tooLarge), from: carol)
                fixture.deliver(has(bob, smallHash, size: Int64(small.count)), from: bob)
            }
            #expect(try asked(fixture, for: smallHash).last == bob.nodeId, "streams \(streams)")
            fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: smallHash, mime: "image/jpeg", bytes: small))
            #expect(fixture.stores.peers.peer(dave.nodeId)?.avatarHash == smallHash, "dave's photo shows")
            let before = try asked(fixture, for: smallHash).filter { $0 == carol.nodeId }.count
            for _ in 0..<3 {
                fixture.advance(60_000)
            }
            #expect(try asked(fixture, for: smallHash).filter { $0 == carol.nodeId }.count == before, "carol is never asked again")
        }
    }

    @Test func aPhotoAMessageAlsoNamesKeepsTheAttachmentsLimitAndIsNotMarked() throws {
        let fixture = EngineFixture(alice, configuration: Self.querying)
        fixture.link(bob, carol, capabilities: android)
        fixture.engine.wantBlob(smallHash, author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: true))
        fixture.deliver(try profile(of: dave, photo: smallHash, version: 5, from: fixture), from: carol)
        #expect(!fixture.engine.blobExchange.isPhotoOnly(smallHash))
        #expect(fixture.transport.accepted == [smallHash] && fixture.transport.photoOnly.isEmpty, "the attachment's 8 MiB")
        fixture.deliver(has(bob, smallHash, size: tooLarge), from: bob)
        fixture.engine.fileOverLimit(smallHash, from: carol.nodeId)
        #expect(fixture.engine.blobExchange.counts.photosOverCeiling == 0)
        #expect(!fixture.engine.blobExchange.photoRefusals.isMarked(smallHash, holder: bob.nodeId))
        #expect(!fixture.engine.blobExchange.photoRefusals.isMarked(smallHash, holder: carol.nodeId))
    }

    // MARK: Adoption

    @Test func anOversizeHeldPhotoIsNeverShownGoesAndIsNotFetchedAgain() throws {
        let fixture = EngineFixture(alice, configuration: Self.querying)
        fixture.link(bob, carol, capabilities: android)
        let hash = BlobHash(of: oversize)
        fixture.stores.blobs.insert(oversize, hash: hash, mime: "image/jpeg", storedAt: 1)
        fixture.transport.clear()
        fixture.deliver(try profile(of: dave, photo: hash, version: 5, from: fixture), from: carol)
        let record = try #require(fixture.stores.peers.peer(dave.nodeId))
        #expect(record.advertisedAvatarHash == hash && record.avatarHash == nil, "named, never shown")
        #expect(!fixture.stores.blobs.contains(hash), "let go once nothing else names it")
        #expect(fixture.engine.blobExchange.isPhotoRefused(hash))
        fixture.advance(60_000)
        #expect(try asked(fixture, for: hash).isEmpty && queried(fixture, for: hash).isEmpty, "the re-want leaves it alone")
    }

    @Test func anOversizePushIsRejectedAndNeverStored() throws {
        let fixture = EngineFixture(alice, configuration: Self.querying)
        fixture.link(bob)
        let hash = BlobHash(of: oversize)
        fixture.deliver(try profile(of: bob, photo: hash, version: 5, from: fixture), from: bob)
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .avatar, hash: hash, mime: "image/jpeg", bytes: oversize))
        #expect(!fixture.stores.blobs.contains(hash))
        #expect(fixture.stores.peers.peer(bob.nodeId)?.avatarHash == nil)
        #expect(fixture.engine.filesRejected == 1)
    }

    @Test func aFaceAdoptedBeforeTheCeilingIsClearedAtTheSweep() throws {
        let fixture = EngineFixture(alice, configuration: Self.querying)
        let hash = BlobHash(of: oversize)
        fixture.stores.blobs.insert(oversize, hash: hash, mime: "image/jpeg", storedAt: 1)
        fixture.deliver(try profile(of: bob, photo: smallHash, version: 5, from: fixture), from: carol)
        // A build without the ceiling adopted it.
        var record = try #require(fixture.stores.peers.peer(bob.nodeId))
        record.avatarHash = hash
        record.advertisedAvatarHash = hash
        fixture.stores.peers.upsert(record)
        _ = fixture.engine.drainEvents()
        fixture.advance(fixture.engine.configuration.sweepMilliseconds)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.avatarHash == nil, "the pin stays, the monogram shows")
        #expect(!fixture.stores.blobs.contains(hash))
        #expect(fixture.engine.drainEvents().contains(.peerUpdated(bob.nodeId)))
        #expect(fixture.engine.blobExchange.isPhotoRefused(hash), "refused for the session, since the held bytes prove its size")
        fixture.link(carol, capabilities: android)
        fixture.advance(60_000)
        #expect(try asked(fixture, for: hash).isEmpty && queried(fixture, for: hash).isEmpty, "no re-want fetches it again")
    }

    @Test func theSessionsRefusalsAreForgottenAtTheNextStart() throws {
        let fixture = try wanting(smallHash)
        fixture.deliver(has(bob, smallHash, size: tooLarge), from: bob)
        #expect(fixture.engine.blobExchange.photoRefusals.isMarked(smallHash, holder: bob.nodeId))
        fixture.engine.forgetPhotoRefusals()
        #expect(!fixture.engine.blobExchange.photoRefusals.isMarked(smallHash, holder: bob.nodeId))
    }

    // MARK: The sealed profile

    /// Alice, ratcheting, having pinned dave's ratchet profile, then handed his sealed profile advertising `photo`.
    private func sealedProfile(advertising photo: BlobHash, holding held: [UInt8]? = nil) throws -> EngineFixture {
        let fixture = try EngineFixture.ratcheting(alice)
        let sealer = try AndroidPeer(dave)
        fixture.deliver(
            try dave.profile(
                name: "Dave",
                version: 10,
                publishedAt: EngineFixture.start,
                capabilities: AndroidPeer.capabilities,
                prekey: sealer.prekey.info
            ),
            from: dave)
        if let held {
            fixture.stores.blobs.insert(held, hash: photo, mime: "image/jpeg", storedAt: 1)
        }
        let update = ProfilePayload(name: "Dave", status: "", avatarHash: photo.string, version: 20)
        let control = MessageContent(body: "", ctl: MessageContent.Control.profile, pr: update)
        let prekey = try fixture.ourPrekey()
        fixture.deliver(
            try sealer.dm(control, to: alice, prekey: prekey, id: frameIdOf("ctl-p1"), sentAt: EngineFixture.start), from: sealer)
        return fixture
    }

    @Test func aSealedProfilesOversizeHeldPhotoIsNeverShownAndGoesOnceTheUnitCommits() throws {
        let hash = BlobHash(of: oversize)
        let fixture = try sealedProfile(advertising: hash, holding: oversize)
        let record = try #require(fixture.stores.peers.peer(dave.nodeId))
        #expect(record.updatedAt == 20, "the presentation moved")
        #expect(record.advertisedAvatarHash == hash && record.avatarHash == nil, "named, never shown")
        #expect(fixture.engine.blobExchange.isPhotoRefused(hash), "declined after the commit")
        #expect(!fixture.stores.blobs.contains(hash), "let go once nothing else names it")
        #expect(!fixture.engine.blobExchange.isWanted(hash))
    }

    @Test func aSealedProfilesPhotoIsFetchedUnderThePhotoCeiling() throws {
        let fixture = try sealedProfile(advertising: smallHash)
        #expect(fixture.engine.blobExchange.isWanted(smallHash), "the sealed profile's photo is wanted")
        #expect(fixture.engine.blobExchange.isPhotoOnly(smallHash))
        #expect(fixture.transport.photoOnly == [smallHash])
    }
}
