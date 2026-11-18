import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Our own profile is signed once for each publish stamp, across restarts (ADR 2026-11.xfcq, after knit-next ADR 2026-11.khhj
/// and its `MeshManagerTest` cases `anEvictedProfileGoesBackByteForByteThoughThePrekeyMoved` and
/// `aCustodiedRowBecomesTheKeptFrameAndItsEvictionMintsNothing`): custody's row first, then this process's copy, then the
/// frame kept beside our profile, put back into custody byte for byte, and only then a fresh signing. Linux's swift-crypto
/// signs deterministically, so each restart here moves the device tag: a second signing of the stamp would then carry other
/// bytes on Linux too, and the device tag the first signing carried tells the two apart.
@Suite struct MeshEngineOwnProfileFrameTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    /// Every fixture's device tag, and the one each restart moves to.
    static let firstTag = "0011223344556677"
    static let laterTag = "8899aabbccddeeff"
    /// Past every room post's 6 h in custody, inside our profile's 12 h before its republish.
    static let later = EngineFixture.start + 6 * 3_600_000 + 60_000

    /// The device tag `frame`'s profile carries.
    private func deviceTag(_ frame: WireEnvelope?) throws -> String? {
        let signed = try #require(frame?.signed)
        return try ProfileContent(decoding: try RelayEnvelope(decoding: signed).payload).deviceTag
    }

    /// Test 1. Alice signs, Bob pins her and carries her profile, her sender quota evicts her own row, and she starts again
    /// over the same stores with another device tag. The start's seed, `ownProfile()`, the link-up push and the digest
    /// reply all answer the first bytes, which still name the first device tag, and Bob's custody keeps its one copy.
    @Test func aRestartAfterTheSenderQuotaEvictedOurProfileServesTheFirstBytesEverywhere() throws {
        let stores = MeshStores.inMemory(custodyLimits: CustodyLimits(maxPerSender: 3))
        let lab = EngineLab([EngineFixture(alice, stores: stores), EngineFixture(bob, seed: 8), EngineFixture(carol, seed: 10)])
        lab.link(0, 1)
        let id = lab[0].ownProfileId
        let first = try #require(lab[0].ownRow)
        #expect(lab[0].keptFrame?.sameBytes(as: first) == true, "the signing kept what it published")
        #expect(lab[1].stores.peers.peer(alice.nodeId) != nil, "bob pinned alice")
        #expect(lab[1].stores.custody.frame(id, now: EngineFixture.start)?.reserved.sameBytes(as: first) == true)
        lab.unlink(0, 1)
        for post in 0..<3 {
            lab[0].clock.advance(1000)
            #expect(lab[0].engine.postToRoom("post \(post)") != nil)
        }
        #expect(lab[0].ownRow == nil, "three newer frames of hers evicted her profile from her own custody")

        let restarted = EngineFixture(alice, stores: stores, wall: Self.later, seed: 9, deviceTag: Self.laterTag)
        #expect(restarted.ownRow?.sameBytes(as: first) == true, "the start's seed put the first bytes back")
        #expect(restarted.engine.ownProfile()?.wire.sameBytes(as: first) == true)
        #expect(try deviceTag(restarted.ownRow) == Self.firstTag, "the first signing's payload, not a second one's")
        #expect(stores.ownProfile.load().publishedAt == EngineFixture.start, "nothing minted")
        for index in [1, 2] {
            lab[index].clock.advance(Self.later - lab[index].clock.wallMilliseconds())
        }
        lab.replace(0, with: restarted)
        lab.link(0, 1)
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)), "alice and bob hold the same live ids")
        #expect(lab[1].stores.custody.frame(id, now: Self.later)?.reserved.sameBytes(as: first) == true, "bob's one copy")
        lab.link(0, 2)
        let written = restarted.transport.written.filter { ExactKey($0.envelope.id) == ExactKey(id) }
        #expect(Set(written.compactMap(\.to)) == [bob.nodeId, carol.nodeId], "the push to bob, and carol's push and digest reply")
        #expect(written.count >= 3 && written.allSatisfy { $0.wire.sameBytes(as: first) }, "every copy is the first bytes")
        #expect(lab[2].stores.custody.frame(id, now: Self.later)?.reserved.sameBytes(as: first) == true)
    }

    /// Test 3. The first start of a build that keeps the frame finds custody's row and nothing kept: the row becomes the
    /// kept frame, and once evicted, the next start puts that row's bytes back.
    @Test func custodysRowBecomesTheKeptFrameAndComesBackAfterAnEviction() throws {
        let stores = MeshStores.inMemory()
        let row = try #require(EngineFixture(alice, stores: stores).ownRow)
        stores.ownProfile.keep(nil)
        #expect(stores.ownProfile.keptFrame() == .absent, "a database from before the kept frame")

        let upgraded = EngineFixture(alice, stores: stores, wall: EngineFixture.start + 60_000, seed: 9, deviceTag: Self.laterTag)
        #expect(stores.ownProfile.keptFrame() == .kept(row), "the row is kept as the frame we published")
        #expect(upgraded.ownRow?.sameBytes(as: row) == true)

        stores.custody.remove(upgraded.ownProfileId)
        let restarted = EngineFixture(alice, stores: stores, wall: EngineFixture.start + 120_000, seed: 10, deviceTag: "ffeeddccbbaa9988")
        #expect(restarted.ownRow?.sameBytes(as: row) == true, "the row's bytes came back")
        #expect(try deviceTag(restarted.ownRow) == Self.firstTag)
        #expect(stores.ownProfile.keptFrame() == .kept(row))
    }

    /// Test 5. A kept frame with one signature byte flipped, custody evicted and no copy in memory: it is refused and
    /// signed afresh, and custody and the kept frame then hold bytes that verify.
    @Test func aKeptFrameThatNoLongerVerifiesIsReplacedByAFreshSigning() throws {
        let stores = MeshStores.inMemory()
        let first = EngineFixture(alice, stores: stores)
        let row = try #require(first.ownRow)
        var flipped = row
        flipped.sig[0] ^= 0x01
        stores.ownProfile.keep(flipped)
        stores.custody.remove(first.ownProfileId)

        let restarted = EngineFixture(alice, stores: stores, wall: EngineFixture.start + 60_000, seed: 9, deviceTag: Self.laterTag)
        let held = try #require(restarted.ownRow)
        #expect(alice.keys.bundle.isValidSignature(held.sig, for: held.signed), "custody holds bytes that verify")
        #expect(held.sig != flipped.sig, "never the flipped frame")
        #expect(try deviceTag(held) == Self.laterTag, "signed afresh")
        #expect(stores.ownProfile.keptFrame() == .kept(held), "the flipped frame is gone, the fresh one kept")
    }

    /// Test 7. Another identity's kept frame over the same stores, as a replaced identity leaves it: refused by its sender,
    /// forgotten, and the new identity signs once and serves that.
    @Test func anotherIdentitysKeptFrameIsIgnoredAndTheNewIdentitySignsOnce() throws {
        let stores = MeshStores.inMemory()
        let theirs = try #require(EngineFixture(alice, stores: stores).keptFrame)
        let fixture = EngineFixture(carol, stores: stores, wall: EngineFixture.start + 60_000, seed: 9)
        let kept = try #require(fixture.keptFrame)
        #expect(!kept.sameBytes(as: theirs))
        let envelope = try RelayEnvelope(decoding: kept.signed)
        #expect(envelope.senderId == carol.nodeId.string && carol.keys.bundle.isValidSignature(kept.sig, for: kept.signed))
        #expect(fixture.ownRow?.sameBytes(as: kept) == true)
        fixture.link(bob)
        let pushed = fixture.transport.written(.profile)
        #expect(pushed.count == 1 && pushed.allSatisfy { $0.wire.sameBytes(as: kept) }, "the one signing goes out")
    }

    /// Blobs' overall-cap case. Alice's re-store at a start tips custody's overall cap, which evicts the largest sender's
    /// oldest frame, Carol's X, as it would for any frame. After the digest rounds Alice and Bob hold the same live ids,
    /// every sender within its quota, and Alice's profile as its first bytes on both.
    @Test func aReStoreTipsTheOverallCapAsAnyFrameWouldAndTheExchangeConverges() throws {
        let limits = CustodyLimits(maxFrames: 6)
        let aliceStores = MeshStores.inMemory(custodyLimits: limits)
        let first = EngineFixture(alice, stores: aliceStores)
        let bobFixture = EngineFixture(bob, stores: .inMemory(custodyLimits: limits), seed: 8)
        let profileId = first.ownProfileId
        let row = try #require(first.ownRow)
        bobFixture.deliver(TestFrame(wire: row, envelope: try RelayEnvelope(decoding: row.signed)), from: alice)
        aliceStores.custody.remove(profileId)

        let carolsProfile = try carol.profile(publishedAt: EngineFixture.start)
        let posts = try (0..<5).map { post in
            try carol.roomPost("c\(post)", id: frameIdOf("carol-\(post)"), sentAt: EngineFixture.start - 10_000 + Int64(post) * 1000)
        }
        for node in [first, bobFixture] {
            node.deliver(carolsProfile, from: carol)
            for post in posts {
                node.deliver(post, from: carol)
            }
        }
        let carolsOldest = posts[0].envelope.id
        #expect(first.stores.custody.contains(carolsOldest) && !first.stores.custody.contains(profileId), "alice at the cap without it")

        let restarted = EngineFixture(alice, stores: aliceStores, wall: EngineFixture.start + 60_000, seed: 9, deviceTag: Self.laterTag)
        #expect(restarted.ownRow?.sameBytes(as: row) == true, "the kept bytes went back")
        #expect(!aliceStores.custody.contains(carolsOldest), "and the cap took carol's oldest frame for them")

        bobFixture.clock.advance(60_000)
        let lab = EngineLab([restarted, bobFixture])
        lab.link(0, 1)
        lab.advance(60_000)
        lab.advance(60_000)
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)), "the same live ids after two digest rounds")
        for index in [0, 1] {
            let live = lab[index].stores.custody.liveFrames(now: lab[index].clock.wallMilliseconds())
            #expect(live.count <= limits.maxFrames)
            let senders = Dictionary(grouping: live, by: \.envelope.senderId)
            #expect(senders.values.allSatisfy { $0.count <= limits.maxPerSender }, "every sender within its quota")
            #expect(
                lab[index].stores.custody.frame(profileId, now: lab[index].clock.wallMilliseconds())?.reserved.sameBytes(as: row) == true)
        }
    }
}
