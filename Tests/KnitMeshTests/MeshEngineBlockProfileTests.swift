import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A block hides a person's new name, status and photo too (knit-ios #37, knit-next #249, the paired change
/// `block-hides-profile`; ADR 2026-10.5wgg). A blocked sender's cleartext profile still pins, is kept as the key's proof,
/// and moves the tag, the bits, the prekey and the watermark, and custody carries and relays it like anyone's; only the
/// presentation stays as it was, until an unblock re-applies the kept frame's (``MeshEngine/reapplyHeldProfile(of:)``).
@Suite struct MeshEngineBlockProfileTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private let start = EngineFixture.start
    private let face = BlobHash(of: Array("a face".utf8))
    private let newFace = BlobHash(of: Array("a new face".utf8))

    /// `peer`'s profile with every field a test sets, `openToChat` among them, which ``TestPeer/profile`` leaves off.
    private func profile(
        of peer: TestPeer,
        name: String,
        status: String,
        version: Int64,
        publishedAt: Int64,
        openToChat: Bool = false,
        avatarHash: BlobHash? = nil,
        deviceTag: String? = nil,
        capabilities: Int64 = 0xF,
        prekey: PrekeyInfo? = nil
    ) throws -> TestFrame {
        let content = ProfileContent(
            name: name,
            status: status,
            avatarHash: avatarHash?.string,
            pubKey: peer.keys.bundle.encoded,
            deviceTag: deviceTag,
            protoVersion: WireProtocol.version,
            capabilities: capabilities,
            prekey: prekey,
            version: version,
            openToChat: openToChat
        )
        let id = "profile-\(peer.nodeId)-\(publishedAt)"
        return try peer.signed(
            RelayEnvelope(type: .profile, id: id, senderId: peer.nodeId.string, sentAt: publishedAt, payload: content.encoded))
    }

    /// Alice, linked to Carol and Dave, holding Bob's first profile at version 10 with his photo shown, and Bob blocked.
    private func blockingBob() throws -> EngineFixture {
        let fixture = EngineFixture(alice)
        fixture.link(carol, dave)
        #expect(fixture.stores.blobs.insert(Array("a face".utf8), hash: face, mime: "image/jpeg", storedAt: start))
        fixture.deliver(
            try profile(
                of: bob, name: "Bob", status: "here", version: 10, publishedAt: start, avatarHash: face, deviceTag: "a1b2c3d4e5f60718"),
            from: carol)
        fixture.engine.block(bob.nodeId)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        return fixture
    }

    /// Bob's newer profile at version 20, received while he is blocked: a dirty name, a new status, open to chat, a new
    /// photo, a new tag, new bits and `prekey`, or prekey 1. CryptoKit randomizes Ed25519, so on the Mac each mint of
    /// prekey 1 is signed anew: a test that compares the row's prekey passes the one it compares with.
    private func newerProfile(prekey: PrekeyInfo? = nil) throws -> TestFrame {
        try profile(
            of: bob,
            name: "Bob\nSmith\u{202E}evil",
            status: "new status",
            version: 20,
            publishedAt: start + 1,
            openToChat: true,
            avatarHash: newFace,
            deviceTag: "0f0e0d0c0b0a0908",
            capabilities: 0x15F,
            prekey: try prekey ?? bob.prekey(id: 1)
        )
    }

    // MARK: Receiving

    @Test func aBlockedPeersNewerProfileMovesEverythingButThePresentation() throws {
        let fixture = try blockingBob()
        let before = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(before.name == "Bob" && before.avatarHash == nil, "the block turned the face to the initial")
        let prekey = try bob.prekey(id: 1)
        let newer = try newerProfile(prekey: prekey)
        fixture.deliver(newer, from: carol)

        let row = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(row.publicKey == bob.keys.bundle.encoded, "still pinned")
        #expect(fixture.stores.peers.profileFrame(of: bob.nodeId)?.signed == newer.wire.signed, "kept as the key's proof")
        #expect(row.deviceTag == "0f0e0d0c0b0a0908")
        #expect(row.capabilities == 0x15F)
        #expect(row.prekey == prekey && row.prekeyProfileAt == 20)
        #expect(row.updatedAt == 20, "the presentation's watermark still moves")
        #expect(row.name == "Bob" && row.status == "here" && !row.openToChat, "the presentation does not")
        #expect(row.advertisedAvatarHash == face && row.avatarHash == nil)
        #expect(fixture.stores.blobs.contains(face), "the photo kept is left to the sweep")

        #expect(fixture.transport.written(.blobRequest).isEmpty, "their new photo is not asked for")
        #expect(!fixture.engine.blobExchange.isWanted(newFace))
        #expect(fixture.stores.custody.contains(newer.envelope.id), "carried like anyone's")
        fixture.advance(150)
        #expect(
            fixture.transport.written(.profile).filter { $0.envelope.id == newer.envelope.id }.map(\.to) == [dave.nodeId], "and relayed")
    }

    @Test func aRekeyedPhoneWithABlockedTagPresentsNothingEvenOnItsFirstProfile() throws {
        let fixture = try blockingBob()
        let rekeyed = TestPeer(seed: 5)
        fixture.deliver(
            try profile(
                of: rekeyed,
                name: "Bob again",
                status: "new keys",
                version: 30,
                publishedAt: start + 2,
                openToChat: true,
                avatarHash: newFace,
                deviceTag: "a1b2c3d4e5f60718"
            ),
            from: carol)

        #expect(fixture.engine.isBlocked(rekeyed.nodeId))
        let row = try #require(fixture.stores.peers.peer(rekeyed.nodeId))
        #expect(row.name.isEmpty && row.status.isEmpty && !row.openToChat)
        #expect(row.advertisedAvatarHash == nil && row.avatarHash == nil)
        #expect(row.deviceTag == "a1b2c3d4e5f60718" && row.updatedAt == 30)
        #expect(fixture.transport.written(.blobRequest).isEmpty)
        #expect(!fixture.engine.blobExchange.isWanted(newFace))
        #expect(fixture.engine.drainEvents() == [.peerUpdated(rekeyed.nodeId)])
    }

    // MARK: Re-applying on unblock

    @Test func theKeptFrameShowsItsCleanedPresentationOnceReapplied() throws {
        let fixture = try blockingBob()
        fixture.deliver(try newerProfile(), from: carol)
        #expect(fixture.stores.blobs.insert(Array("a new face".utf8), hash: newFace, mime: "image/jpeg", storedAt: start))
        // The list alone, as `unblock` would re-apply first.
        fixture.stores.blocks.unblock(bob.nodeId, deviceTag: nil)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        let held = try #require(fixture.stores.peers.peer(bob.nodeId))

        #expect(fixture.engine.reapplyHeldProfile(of: bob.nodeId))
        let row = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(row.name == "Bob Smithevil", "cleaned as a profile that lands is")
        #expect(row.status == "new status" && row.openToChat)
        #expect(row.advertisedAvatarHash == newFace && row.avatarHash == newFace)
        #expect(row.updatedAt == held.updatedAt && row.prekeyProfileAt == held.prekeyProfileAt && row.deviceTag == held.deviceTag)
        #expect(row.capabilities == held.capabilities && row.prekey == held.prekey && row.verified == held.verified)
        #expect(fixture.engine.drainEvents() == [.peerUpdated(bob.nodeId)])
        #expect(fixture.transport.written.isEmpty, "not a delivery: nothing sent, asked for or relayed")

        #expect(!fixture.engine.reapplyHeldProfile(of: bob.nodeId), "applied, so nothing moves again")
        #expect(fixture.engine.drainEvents().isEmpty)
    }

    @Test func aFrameAtTheRowsOwnVersionApplies() throws {
        let fixture = try blockingBob()
        fixture.deliver(try newerProfile(), from: carol)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.updatedAt == 20, "the blocked profile moved the watermark to its own version")
        #expect(fixture.engine.reapplyHeldProfile(of: bob.nodeId))
        #expect(fixture.stores.peers.peer(bob.nodeId)?.status == "new status")
    }

    @Test func noFrameHeldAppliesNothing() {
        let fixture = EngineFixture(alice)
        let row = PeerRecord(nodeId: bob.nodeId, name: "Bob", status: "", publicKey: bob.keys.bundle.encoded, updatedAt: 10)
        fixture.stores.peers.upsert(row)
        #expect(!fixture.engine.reapplyHeldProfile(of: bob.nodeId))
        #expect(fixture.stores.peers.peer(bob.nodeId) == row)
        #expect(!fixture.engine.reapplyHeldProfile(of: carol.nodeId), "nor with no row either")
        #expect(fixture.engine.drainEvents().isEmpty)
    }

    @Test func aFrameOlderThanTheRowsWatermarkAppliesNothing() throws {
        let fixture = try blockingBob()
        fixture.deliver(try newerProfile(), from: carol)
        var raised = try #require(fixture.stores.peers.peer(bob.nodeId))
        raised.updatedAt = 21
        fixture.stores.peers.upsert(raised)
        _ = fixture.engine.drainEvents()
        #expect(!fixture.engine.reapplyHeldProfile(of: bob.nodeId))
        #expect(fixture.stores.peers.peer(bob.nodeId) == raised)
        #expect(fixture.engine.drainEvents().isEmpty)
    }

    @Test func aFrameUnderAnotherKeyOrFromAnotherSenderAppliesNothing() throws {
        let fixture = try blockingBob()
        fixture.deliver(try newerProfile(), from: carol)
        var forged = try #require(fixture.stores.peers.peer(bob.nodeId))
        forged.publicKey = carol.keys.bundle.encoded
        fixture.stores.peers.upsert(forged)
        #expect(!fixture.engine.reapplyHeldProfile(of: bob.nodeId), "the kept frame names a key the row does not pin")
        #expect(fixture.stores.peers.peer(bob.nodeId) == forged)

        let other = EngineFixture(alice)
        other.deliver(try profile(of: bob, name: "Bob", status: "", version: 10, publishedAt: start), from: bob)
        let carols = try profile(of: carol, name: "Carol", status: "", version: 40, publishedAt: start + 9)
        other.stores.peers.recordProfileFrame(carols.wire, of: bob.nodeId, sentAt: start + 9)
        #expect(!other.engine.reapplyHeldProfile(of: bob.nodeId), "a frame kept under Bob that Carol signed")
        #expect(other.stores.peers.peer(bob.nodeId)?.name == "Bob")
    }
}
