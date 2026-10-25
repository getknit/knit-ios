import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The asker's half of resuming a cut transfer (knit-next ADR 2026-10.wtyc, knit-ios #2): its asks name the bytes it kept,
/// a spliced file that fails its hash starts over from byte 0, and a blob held some way or other drops its prefix. Twins of
/// `BlobExchangeTest`'s resume cases (`BlobExchangeTest.kt:923-1157` at knit-next `0108d8df1`).
@Suite struct MeshEngineBlobResumeTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    /// A photo past the 16 KiB a prefix must reach to be kept, and the length of the prefix the tests keep of it.
    private let photo: [UInt8] = (0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
    private let kept = 20_000
    private var photoHash: BlobHash { BlobHash(of: photo) }

    private func want(_ fixture: EngineFixture, _ hash: BlobHash) {
        fixture.engine.wantBlob(hash, author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: true))
    }

    /// Each blob request written, as (to, hash, offset).
    private func asks(_ fixture: EngineFixture) throws -> [Ask] {
        try fixture.transport.written(.blobRequest).map { written in
            let content = try BlobRequestContent(decoding: written.envelope.payload)
            return Ask(to: written.to, hash: content.hash, offset: content.offset)
        }
    }

    private struct Ask: Equatable {
        var to: NodeId?
        var hash: String
        var offset: Int64?
    }

    /// A file of the photo's length that is not the photo, as a bad splice is.
    private func badSplice(from peer: TestPeer, resumedFrom: Int) -> InboundFile {
        InboundFile(
            from: peer.nodeId,
            kind: .attachment,
            hash: photoHash,
            mime: "image/png",
            bytes: [UInt8](repeating: 0, count: photo.count),
            resumedFrom: resumedFrom
        )
    }

    @Test func theFirstAskAndTheTickBothCarryTheOffset() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.transport.clear()
        want(fixture, photoHash)
        #expect(
            try asks(fixture) == [Ask(to: bob.nodeId, hash: photoHash.string, offset: nil)], "nothing kept: the bytes an older build sent")
        let other = BlobHash(of: Array("a second photo".utf8))
        #expect(
            fixture.engine.partials.keep(other, bytes: [UInt8](repeating: 1, count: kept), basedOn: nil, now: 0), "a link was cut 20 kB in")
        want(fixture, other)
        fixture.clock.advance(BlobExchange.cycleMilliseconds)
        fixture.engine.stepBlobs()
        let expected = [
            Ask(to: bob.nodeId, hash: photoHash.string, offset: nil), Ask(to: bob.nodeId, hash: other.string, offset: Int64(kept)),
            Ask(to: bob.nodeId, hash: photoHash.string, offset: nil), Ask(to: bob.nodeId, hash: other.string, offset: Int64(kept)),
        ]
        #expect(try asks(fixture) == expected)
    }

    @Test func aSpliceThatFailsItsHashDropsThePrefixAndOpensARoundForTheWholeBlobAtOnce() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        want(fixture, photoHash)
        fixture.engine.partials.keep(photoHash, bytes: [UInt8](repeating: 0, count: kept), basedOn: nil, now: 0)
        fixture.transport.clear()
        fixture.engine.receiveFile(badSplice(from: carol, resumedFrom: kept))
        #expect(fixture.engine.blobCounts.splicesRefused == 1)
        #expect(fixture.engine.partials.length(photoHash) == 0, "the prefix may be what was wrong")
        let now = try asks(fixture)
        #expect(now.count == 1 && now.allSatisfy { $0.hash == photoHash.string && $0.offset == nil }, "from byte 0, now, one ask")
        fixture.advance(BlobExchange.firstAskGraceMilliseconds)
        #expect(Set(try asks(fixture).map(\.to)) == [bob.nodeId, carol.nodeId], "the round widens after the first ask's grace")
        #expect(!fixture.stores.blobs.contains(photoHash) && fixture.engine.blobExchange.isWanted(photoHash), "still wanted")
        #expect(fixture.engine.filesRejected == 1)
        #expect(
            fixture.log.all.contains(
                "info mesh blob \(photoHash.string.prefix(8))… splice from \(carol.nodeId) refused; asked again from 0"))
    }

    @Test func theHolderWhoseTailFailedIsPassedOverThisCycle() throws {
        // A queried round: the failing holder still says HAVE, and the other is fetched from.
        let fixture = EngineFixture(alice, configuration: MeshConfiguration(queriesBlobHolders: true))
        fixture.link(bob, carol, capabilities: Capabilities.local.union(.blobHave))
        want(fixture, photoHash)
        fixture.engine.partials.keep(photoHash, bytes: [UInt8](repeating: 0, count: kept), basedOn: nil, now: 0)
        fixture.transport.clear()
        fixture.engine.receiveFile(badSplice(from: bob, resumedFrom: kept))
        let queries = fixture.transport.written(.blobHave)
        #expect(queries.map(\.to) == [bob.nodeId, carol.nodeId], "a forced cycle queries again")
        for (peer, query) in zip([bob, carol], queries) {
            let have = BlobHasItem(hash: photoHash.string, state: .have, size: Int64(photo.count))
            fixture.deliver(peer.blobHas([have], re: query.envelope.id), from: peer)
        }
        #expect(try asks(fixture) == [Ask(to: carol.nodeId, hash: photoHash.string, offset: nil)])
    }

    @Test func aFailedSpliceStaysQuietWhileTheBlobIsArrivingOrWhenNoPrefixWasLeft() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        want(fixture, photoHash)
        fixture.engine.partials.keep(photoHash, bytes: [UInt8](repeating: 0, count: kept), basedOn: nil, now: 0)
        fixture.transport.clear()
        fixture.transport.arrivingFileKeys = [photoHash] // another link streams it in now (knit-next ADR 2026-09.4tx5)
        fixture.engine.receiveFile(badSplice(from: bob, resumedFrom: kept))
        #expect(fixture.engine.partials.length(photoHash) == 0, "the prefix still goes")
        #expect(try asks(fixture).isEmpty, "but nobody is asked while it arrives")
        fixture.transport.arrivingFileKeys = []
        fixture.engine.receiveFile(badSplice(from: bob, resumedFrom: kept))
        #expect(try asks(fixture).isEmpty, "no live prefix dropped, so no ask a peer could set off at will")
        #expect(fixture.engine.blobCounts.splicesRefused == 2, "each counted")
    }

    @Test func aWholeFileThatFailsItsHashLeavesTheKeptPrefixAlone() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        want(fixture, photoHash)
        fixture.engine.partials.keep(photoHash, bytes: Array(photo.prefix(kept)), basedOn: nil, now: 0)
        fixture.transport.clear()
        fixture.engine.receiveFile(badSplice(from: bob, resumedFrom: 0))
        #expect(fixture.engine.partials.length(photoHash) == kept, "the holder's bytes were wrong, not ours")
        #expect(try asks(fixture).isEmpty, "the next step asks again, as it always has")
        #expect(fixture.engine.blobCounts.splicesRefused == 0)
    }

    @Test func aStoredBlobOrOneObtainedOffMeshDropsItsKeptPrefix() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        want(fixture, photoHash)
        fixture.engine.partials.keep(photoHash, bytes: Array(photo.prefix(kept)), basedOn: nil, now: 0)
        fixture.engine.receiveFile(
            InboundFile(from: bob.nodeId, kind: .attachment, hash: photoHash, mime: "image/png", bytes: photo, resumedFrom: kept))
        #expect(fixture.stores.blobs.contains(photoHash))
        #expect(fixture.engine.partials.length(photoHash) == 0, "landed: nothing left to resume")
        // Another arrives some other way while a prefix is kept: the next step finds it held.
        let other = photo.reversed().map(\.self)
        let otherHash = BlobHash(of: other)
        want(fixture, otherHash)
        fixture.engine.partials.keep(otherHash, bytes: Array(other.prefix(kept)), basedOn: nil, now: 0)
        fixture.stores.blobs.insert(other, hash: otherHash, mime: "image/png", storedAt: EngineFixture.start)
        fixture.engine.stepBlobs()
        #expect(fixture.engine.partials.length(otherHash) == 0)
    }

    @Test func aBlobTheStoreFailsToHoldKeepsItsPrefix() {
        // A failed insert answers as one already held does, so the prefix goes only once the blob reads as held.
        let base = MeshStores.inMemory()
        let stores = MeshStores(
            custody: base.custody,
            peers: base.peers,
            messages: base.messages,
            conversations: base.conversations,
            blocks: base.blocks,
            groups: base.groups,
            ownProfile: base.ownProfile,
            blobs: RefusingBlobStore(),
            ratchet: base.ratchet,
            groupRatchet: base.groupRatchet,
            transactor: base.transactor
        )
        let fixture = EngineFixture(alice, stores: stores)
        fixture.link(bob)
        want(fixture, photoHash)
        fixture.engine.partials.keep(photoHash, bytes: Array(photo.prefix(kept)), basedOn: nil, now: 0)
        fixture.engine.receiveFile(
            InboundFile(from: bob.nodeId, kind: .attachment, hash: photoHash, mime: "image/png", bytes: photo, resumedFrom: kept))
        #expect(fixture.engine.partials.length(photoHash) == kept)
    }

    @Test func aFileIsTakenOffTheLinkOnceTheStoreHasAnsweredSoARefusedSpliceStillAsksFromZero() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        want(fixture, photoHash)
        fixture.engine.partials.keep(photoHash, bytes: [UInt8](repeating: 0, count: kept), basedOn: nil, now: 0)
        fixture.transport.clear()
        fixture.transport.takenLeavesArriving = true
        fixture.transport.arrivingFileKeys = [photoHash] // the spliced file, landing: the link counts it until it is taken
        fixture.engine.receiveFile(badSplice(from: bob, resumedFrom: kept))
        #expect(fixture.transport.taken.first.map { [$0.from.string, $0.hash.string] } == [bob.nodeId.string, photoHash.string])
        #expect(try asks(fixture) == [Ask(to: bob.nodeId, hash: photoHash.string, offset: nil)], "its own landing kept no ask quiet")
        fixture.transport.arrivingFileKeys = [photoHash]
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: photoHash, mime: "image/png", bytes: photo))
        #expect(fixture.stores.blobs.contains(photoHash))
        #expect(!fixture.transport.arrivingFileKeys.contains(photoHash), "and taken once it was held")
    }

    @Test func theSweepDropsAPrefixPastItsHourAndOneWhoseBlobIsHeld() {
        let fixture = EngineFixture(alice)
        let held = BlobHash(of: Array("held".utf8))
        fixture.engine.partials.keep(
            photoHash, bytes: [UInt8](repeating: 0, count: 20_000), basedOn: nil, now: fixture.clock.monotonicMilliseconds())
        fixture.engine.partials.keep(
            held, bytes: [UInt8](repeating: 0, count: 20_000), basedOn: nil, now: fixture.clock.monotonicMilliseconds())
        fixture.stores.blobs.insert(Array("held".utf8), hash: held, mime: "image/png", storedAt: EngineFixture.start)
        fixture.engine.sweep()
        #expect(fixture.engine.partials.length(held) == 0, "held now: nothing to resume")
        #expect(fixture.engine.partials.length(photoHash) == 20_000)
        fixture.clock.advance(PartialBlobBook.Limits().ttlMilliseconds + 1)
        fixture.engine.sweep()
        #expect(fixture.engine.partials.length(photoHash) == 0, "past its hour")
    }

    @Test func aRestartWithNoWantLeftMakesOneWithNoBudgetAndPassesTheFailingHolderOver() {
        // The want was swept or evicted while its prefix was kept (`BlobExchange.kt:2358-2361`): made afresh, it mints no
        // root, and the next re-arm from the stores makes it one again.
        var exchange = BlobExchange(queriesHolders: true)
        exchange.restartFromZero(photoHash, failing: bob.nodeId, now: 5000, wall: EngineFixture.start)
        let want = exchange.wants[photoHash]
        #expect(exchange.wanted == [photoHash])
        #expect(want?.budget == 0 && want?.wantedAt == 5000 && want?.cycleAt == 5000)
        #expect(want?.failed == [bob.nodeId])
    }

    @Test func aRestartsFreshWantKeepsTheWantedSetToItsBound() {
        var exchange = BlobExchange(queriesHolders: true)
        let others = (0..<BlobExchange.maxWanted).map { BlobHash(of: [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)]) }
        for hash in others {
            _ = exchange.recordWant(
                hash, now: 0, wall: EngineFixture.start, author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: true))
        }
        exchange.restartFromZero(photoHash, failing: nil, now: 1, wall: EngineFixture.start)
        #expect(exchange.wanted.count == BlobExchange.maxWanted)
        #expect(exchange.wanted.last == photoHash && !exchange.isWanted(others[0]), "the oldest goes")
    }

    @Test func theIntakesWindowIsTheExchangesRound() {
        // `RESUME_WINDOW_MS = BlobExchange.ROUND_MS`: the intake, in KnitWire, cannot name the exchange's constant.
        #expect(FileIntake.resumeWindowMilliseconds == BlobExchange.cycleMilliseconds)
    }
}

/// A blob store whose every write fails, as a full disk's does: it holds nothing.
private final class RefusingBlobStore: BlobStore {
    func contains(_: BlobHash) -> Bool { false }
    func held(among _: Set<BlobHash>) -> Set<BlobHash> { [] }
    func mime(of _: BlobHash) -> String? { nil }
    func size(of _: BlobHash) -> Int? { nil }
    func read(_: BlobHash, offset _: Int, count _: Int) -> [UInt8]? { nil }
    func bytes(of _: BlobHash) -> [UInt8]? { nil }
    func insert(_: [UInt8], hash _: BlobHash, mime _: String, storedAt _: Int64) -> Bool { false }
    func remove(_: BlobHash) {
        // Nothing is held.
    }
    func allHashes() -> [BlobHash] { [] }
    func totalBytes(among _: Set<BlobHash>) -> Int { 0 }
}
