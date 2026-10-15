import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// A peer's prekey taken in from its profile on a watermark of its own (`InboundPipeline.handleProfile`,
/// `storeProfileRow` and `verifiedPrekey` in knit-next, `InboundPipeline.kt:3159-3368`). It runs with the ratchet's
/// switch off, as every fixture here has it: taking a prekey in sends nothing (ADR 2026-10.5sk9).
@Suite struct MeshEnginePrekeyIntakeTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let start = EngineFixture.start

    private func bobsRecord(_ fixture: EngineFixture) throws -> PeerRecord {
        try #require(fixture.stores.peers.peer(bob.nodeId))
    }

    @Test func aVerifiedPrekeyIsPinnedWithTheProfilesVersionAsItsWatermark() throws {
        let fixture = EngineFixture(alice)
        let prekey = try bob.prekey(id: 1)
        let profile = try bob.profile(version: 5, publishedAt: start, capabilities: 0x15F, prekey: prekey)
        fixture.deliver(profile, from: bob)
        let peer = try bobsRecord(fixture)
        #expect(peer.prekey == prekey)
        #expect(peer.prekeyProfileAt == 5)
        #expect(peer.updatedAt == 5)
        #expect(peer.capabilities == 0x15F)
        #expect(fixture.engine.drainEvents() == [.peerUpdated(bob.nodeId)])
        // The same profile served again, under another stamp, changes nothing.
        fixture.deliver(try bob.profile(version: 5, publishedAt: start + 1, capabilities: 0x15F, prekey: prekey), from: carol)
        #expect(try bobsRecord(fixture) == peer)
        #expect(fixture.engine.drainEvents().isEmpty)
    }

    @Test func aNewerProfileWithNoPrekeyOrABadOneClearsThePin() throws {
        let fixture = EngineFixture(alice)
        let good = try bob.prekey(id: 1)
        fixture.deliver(try bob.profile(version: 5, publishedAt: start, prekey: good), from: bob)
        fixture.deliver(try bob.profile(version: 6, publishedAt: start + 1), from: bob)
        #expect(try bobsRecord(fixture).prekey == nil, "the peer stopped serving it")
        #expect(try bobsRecord(fixture).prekeyProfileAt == 6)

        var badSignature = try bob.prekey(id: 2)
        badSignature.sig[0] ^= 1
        // A short key, signed as it is: its signature verifies, and its length does not.
        let shortKey = Array(good.pub.prefix(31))
        let short = PrekeyInfo(id: 3, pub: shortKey, sig: try bob.keys.signature(for: RatchetCrypto.spkSigningBytes(id: 3, pub: shortKey)))
        // Carol's own prekey, which Bob's key never signed.
        let carols = try carol.prekey(id: 4)
        for (offset, bad) in [badSignature, short, carols].enumerated() {
            let version = Int64(7 + 2 * offset)
            fixture.deliver(try bob.profile(version: version, publishedAt: start + 2 + Int64(2 * offset), prekey: good), from: bob)
            #expect(try bobsRecord(fixture).prekey == good)
            fixture.deliver(try bob.profile(version: version + 1, publishedAt: start + 3 + Int64(2 * offset), prekey: bad), from: bob)
            let peer = try bobsRecord(fixture)
            #expect(peer.prekey == nil, "\(bad.id)")
            #expect(peer.prekeyProfileAt == version + 1, "a bad prekey moves the watermark as no prekey does")
        }
        #expect(fixture.log.all.filter { $0 == "warning mesh ignored a bad prekey from \(bob.nodeId)" }.count == 3)
    }

    @Test func aProfileOlderOnBothWatermarksChangesNothing() throws {
        let fixture = EngineFixture(alice)
        let newer = try bob.prekey(id: 2)
        fixture.deliver(try bob.profile(name: "New", version: 10, publishedAt: start, prekey: newer), from: bob)
        let held = try bobsRecord(fixture)
        let proof = fixture.stores.peers.profileFrame(of: bob.nodeId)
        _ = fixture.engine.drainEvents()
        let older = try bob.profile(name: "Old", version: 9, publishedAt: start + 1, capabilities: 0x9, prekey: try bob.prekey(id: 1))
        fixture.deliver(older, from: bob)
        #expect(try bobsRecord(fixture) == held)
        #expect(fixture.stores.peers.profileFrame(of: bob.nodeId) == proof, "it proves nothing newer")
        #expect(fixture.engine.drainEvents().isEmpty)
    }

    @Test func aProfileOlderOnThePresentationButNewerOnThePrekeyStillMovesThePrekey() throws {
        // A sealed profile update moves the presentation and carries no prekey (knit-next ADR 020), so the cleartext
        // profile behind it is older on the first watermark and newer on the second. That update is a later phase's; the
        // row stands in for it here.
        let stores = MeshStores.inMemory()
        let photo = try #require(BlobHash(String(repeating: "a", count: 64)))
        stores.peers.upsert(
            PeerRecord(
                nodeId: bob.nodeId,
                name: "Sealed",
                status: "away",
                publicKey: bob.keys.bundle.encoded,
                capabilities: 0xF,
                updatedAt: 20,
                openToChat: true,
                avatarHash: photo,
                advertisedAvatarHash: photo,
                prekey: try bob.prekey(id: 1),
                prekeyProfileAt: 10
            )
        )
        let fixture = EngineFixture(alice, stores: stores)
        let fresh = try bob.prekey(id: 2)
        let other = String(repeating: "b", count: 64)
        fixture.deliver(
            try bob.profile(name: "Clear", version: 15, publishedAt: start, avatarHash: other, capabilities: 0x15F, prekey: fresh),
            from: bob)
        let peer = try bobsRecord(fixture)
        #expect(peer.prekey == fresh)
        #expect(peer.prekeyProfileAt == 15)
        #expect(peer.name == "Sealed" && peer.status == "away" && peer.openToChat, "the presentation stays as the newer update left it")
        #expect(peer.avatarHash == photo && peer.advertisedAvatarHash == photo)
        #expect(peer.updatedAt == 20, "never moved back")
        #expect(peer.capabilities == 0x15F, "the bits ride the cleartext profile with the prekey, as Android takes them")
        #expect(fixture.stores.peers.profileFrame(of: bob.nodeId) != nil)
        #expect(fixture.transport.written(.blobRequest).isEmpty, "no photo is asked for on a presentation that did not move")
    }

    @Test func aFrameBetweenTheWatermarksKeepsTheNewerProofAndAsksForNoPhoto() throws {
        // The row as a sealed update and a cleartext profile at 10 left it, and the proof of key this node hands on, from
        // a later publish stamp than the frame below. The frame moves the prekey alone.
        let stores = MeshStores.inMemory()
        let photo = try #require(BlobHash(String(repeating: "a", count: 64)))
        stores.peers.upsert(
            PeerRecord(
                nodeId: bob.nodeId,
                name: "Sealed",
                status: "",
                publicKey: bob.keys.bundle.encoded,
                updatedAt: 20,
                avatarHash: photo,
                advertisedAvatarHash: photo,
                prekey: try bob.prekey(id: 1),
                prekeyProfileAt: 10
            )
        )
        let proof = try bob.profile(
            name: "Sealed", version: 20, publishedAt: start + 100, avatarHash: photo.string, prekey: try bob.prekey(id: 1))
        stores.peers.recordProfileFrame(proof.wire, of: bob.nodeId, sentAt: start + 100)
        let fixture = EngineFixture(alice, stores: stores)
        fixture.link(carol)
        fixture.transport.clear()
        let between = try bob.profile(
            name: "Clear", version: 15, publishedAt: start, avatarHash: String(repeating: "b", count: 64), prekey: try bob.prekey(id: 2))
        fixture.deliver(between, from: bob)
        fixture.advance(1000)
        #expect(try bobsRecord(fixture).prekey?.id == 2)
        let kept = try #require(fixture.stores.peers.profileFrame(of: bob.nodeId))
        #expect(kept.encoded == KeyExchange.served(proof.wire).encoded, "the newer proof, byte for byte")
        #expect(fixture.transport.written(.blobRequest).isEmpty, "Carol could have been asked, and the presentation did not move")
    }

    @Test func aFrameBetweenTheWatermarksAnswersTheKeyRequestWaitingForIt() throws {
        // A pin kept before its proof was (schema v2), and a cold key cache: Carol's request for Bob's key waits, and the
        // frame that moves his prekey alone is the first proof this node can hand on.
        let stores = MeshStores.inMemory()
        stores.peers.upsert(
            PeerRecord(
                nodeId: bob.nodeId,
                name: "Sealed",
                status: "",
                publicKey: bob.keys.bundle.encoded,
                updatedAt: 20,
                prekey: try bob.prekey(id: 1),
                prekeyProfileAt: 10
            )
        )
        let fixture = EngineFixture(alice, stores: stores)
        let carols = EngineFixture(carol)
        fixture.link(carol)
        carols.link(alice)
        carry(from: fixture, to: carols)
        carry(from: carols, to: fixture)
        #expect(fixture.stores.peers.profileFrame(of: bob.nodeId) == nil)
        fixture.deliver(try carol.keyRequest(for: [bob.nodeId], id: "req-1"), from: carol)
        #expect(fixture.transport.written(.profile).isEmpty, "nothing to serve yet")
        fixture.transport.clear()
        let between = try bob.profile(name: "Clear", version: 15, publishedAt: start, prekey: try bob.prekey(id: 2))
        fixture.deliver(between, from: bob)
        let served = fixture.transport.written(.profile).filter { !$0.wire.relay }
        #expect(served.map(\.to) == [carol.nodeId], "exactly one, to the neighbour that asked")
        #expect(served.first?.wire.signed == between.wire.signed && served.first?.wire.sig == between.wire.sig, "verbatim")
        // Carol's own engine takes it, and one digest round finds nothing either side lacks.
        carry(from: fixture, to: carols)
        #expect(carols.stores.peers.peer(bob.nodeId)?.prekey?.id == 2)
        for (from, to) in [(fixture, carols), (carols, fixture)] {
            from.engine.receiveDigest(to.stores.custody.liveIds(now: start), from: to.me.nodeId)
            carry(from: from, to: to)
        }
        #expect(Set(fixture.stores.custody.liveIds(now: start)) == Set(carols.stores.custody.liveIds(now: start)))
        #expect(fixture.stores.custody.liveIds(now: start).contains(between.envelope.id))
    }

    /// Hands `to` every frame `from` wrote to it, as the link between them would.
    private func carry(from: EngineFixture, to: EngineFixture) {
        let written = from.transport.written.filter { $0.to == to.me.nodeId }
        from.transport.clear()
        for frame in written {
            to.engine.receive(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: from.me.nodeId))
        }
    }

    @Test func aProfileNewerOnThePresentationButOlderOnThePrekeyKeepsThePrekey() throws {
        let stores = MeshStores.inMemory()
        let held = try bob.prekey(id: 2)
        stores.peers.upsert(
            PeerRecord(
                nodeId: bob.nodeId,
                name: "Old",
                status: "",
                publicKey: bob.keys.bundle.encoded,
                updatedAt: 5,
                prekey: held,
                prekeyProfileAt: 10
            )
        )
        let fixture = EngineFixture(alice, stores: stores)
        fixture.deliver(try bob.profile(name: "New", version: 7, publishedAt: start, prekey: try bob.prekey(id: 1)), from: bob)
        let peer = try bobsRecord(fixture)
        #expect(peer.name == "New")
        #expect(peer.updatedAt == 7)
        #expect(peer.prekey == held)
        #expect(peer.prekeyProfileAt == 10)
    }

    @Test func aFirstProfileStartsFromWatermarksOfZeroAsAndroidsRowDoes() throws {
        // `PeerEntity(senderId)` starts at 0 (`InboundPipeline.kt:3301`), so a version below 0 leaves the presentation's
        // watermark at 0 while the prekey's takes the version.
        let fixture = EngineFixture(alice)
        fixture.deliver(try bob.profile(version: -5, publishedAt: start, prekey: try bob.prekey(id: 1)), from: bob)
        #expect(try bobsRecord(fixture).updatedAt == 0)
        #expect(try bobsRecord(fixture).prekeyProfileAt == -5)
        fixture.deliver(try bob.profile(name: "Later", version: -1, publishedAt: start + 1, prekey: try bob.prekey(id: 2)), from: bob)
        let peer = try bobsRecord(fixture)
        #expect(peer.name == "Peer", "older than 0 on the presentation's watermark")
        #expect(peer.prekey?.id == 2)
        #expect(peer.prekeyProfileAt == -1)
    }

    @Test func ourOwnProfileComingBackPinsNoPrekey() throws {
        let fixture = EngineFixture(alice)
        fixture.deliver(try alice.profile(version: 9, publishedAt: start - 10, prekey: try alice.prekey(id: 1)), from: bob)
        #expect(fixture.stores.peers.peer(alice.nodeId) == nil)
    }
}
