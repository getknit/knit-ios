import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// knit-peer's lying blob store: honest with nothing set, junk of the size set under a hash, a held blob's bytes kept
/// back, and writes and the sweeps' reads always the wrapped store's.
@Suite struct LyingBlobStoreTests {
    private let held = fixtureBytes(300, seed: 1)
    private let other = fixtureBytes(40, seed: 2)
    /// A hash nothing holds.
    private let absent = BlobHash(of: fixtureBytes(10, seed: 3))

    /// A memory store holding ``held`` and ``other``, and the liar over it.
    private func filled() -> (MemoryBlobStore, LyingBlobStore) {
        let inner = MemoryBlobStore()
        inner.insert(held, hash: BlobHash(of: held), mime: "image/png", storedAt: 100)
        inner.insert(other, hash: BlobHash(of: other), mime: "image/webp", storedAt: 300)
        return (inner, LyingBlobStore(wrapping: inner))
    }

    @Test func withNothingSetEveryReadIsTheWrappedStores() {
        let (inner, lying) = filled()
        let all: Set = [BlobHash(of: held), BlobHash(of: other), absent]
        for hash in all {
            #expect(lying.contains(hash) == inner.contains(hash))
            #expect(lying.mime(of: hash) == inner.mime(of: hash))
            #expect(lying.size(of: hash) == inner.size(of: hash))
            #expect(lying.bytes(of: hash) == inner.bytes(of: hash))
            for (offset, count) in [(0, 10), (0, 1000), (295, 10), (300, 1), (301, 1), (-1, 1), (0, -1), (12, 0)] {
                #expect(lying.read(hash, offset: offset, count: count) == inner.read(hash, offset: offset, count: count))
            }
        }
        #expect(lying.held(among: all) == inner.held(among: all))
        #expect(lying.allHashes() == inner.allHashes())
        #expect(lying.hashes(storedBefore: 200) == inner.hashes(storedBefore: 200))
        #expect(lying.totalBytes(among: all) == inner.totalBytes(among: all))
        #expect(lying.junk.isEmpty && lying.withheld.isEmpty && lying.junkBytesServed == 0)
    }

    @Test func junkReadsAsHeldAtItsSizeWhateverIsHeld() throws {
        let (inner, lying) = filled()
        let mine = BlobHash(of: held)
        try lying.setJunk(absent, bytes: 5000)
        try lying.setJunk(mine, bytes: 1000)

        #expect(lying.junk == [absent: 5000, mine: 1000])
        #expect(lying.contains(absent) && !inner.contains(absent))
        #expect(lying.held(among: [absent, mine, BlobHash(of: other)]) == [absent, mine, BlobHash(of: other)])
        #expect(lying.size(of: absent) == 5000 && lying.size(of: mine) == 1000)
        #expect(lying.mime(of: absent) == "image/jpeg" && lying.mime(of: mine) == "image/jpeg")
        let whole = try #require(lying.bytes(of: mine))
        #expect(whole.count == 1000 && whole != Array(held.prefix(1000)), "junk, not the bytes held")
        #expect(inner.bytes(of: mine) == held, "the held blob itself is untouched")
    }

    @Test func junkIsTheSameBytesWhicheverReadReachesThem() throws {
        let lying = LyingBlobStore(wrapping: MemoryBlobStore())
        let hash = absent
        try lying.setJunk(hash, bytes: 1000)
        let whole = try #require(lying.read(hash, offset: 0, count: 1000))
        var pieced: [UInt8] = []
        for offset in stride(from: 0, to: 1000, by: 37) {
            pieced += try #require(lying.read(hash, offset: offset, count: 37))
        }
        #expect(pieced == whole, "a resumed prefix splices onto the same junk")
        #expect(lying.bytes(of: hash) == whole)
        #expect(Set(whole).count > 100, "junk, not one byte repeated")

        let another = BlobHash(of: other)
        try lying.setJunk(another, bytes: 1000)
        #expect(lying.read(another, offset: 0, count: 1000) != whole, "each hash its own junk")
    }

    @Test func junkReadsPastItsEndAsTheMemoryStoreReadsPastABlobs() throws {
        let inner = MemoryBlobStore()
        let real = fixtureBytes(100, seed: 9)
        let hash = BlobHash(of: real)
        inner.insert(real, hash: hash, mime: "image/jpeg", storedAt: 1)
        let lying = LyingBlobStore(wrapping: MemoryBlobStore())
        try lying.setJunk(hash, bytes: 100)
        for (offset, count) in [(90, 50), (100, 5), (101, 1), (-1, 5), (0, -1), (50, 0)] {
            #expect(lying.read(hash, offset: offset, count: count)?.count == inner.read(hash, offset: offset, count: count)?.count)
        }
    }

    @Test func junkServedCountsTheBytesRead() throws {
        let lying = LyingBlobStore(wrapping: MemoryBlobStore())
        try lying.setJunk(absent, bytes: 100)
        _ = lying.read(absent, offset: 0, count: 60)
        _ = lying.read(absent, offset: 60, count: 60)
        _ = lying.read(absent, offset: 200, count: 60)
        #expect(lying.junkBytesServed == 100)
    }

    @Test func junkSizeMustBeOneThatCouldStream() throws {
        let lying = LyingBlobStore(wrapping: MemoryBlobStore())
        #expect(throws: LyingBlobStore.JunkSizeRefused(bytes: 0)) { try lying.setJunk(absent, bytes: 0) }
        #expect(throws: LyingBlobStore.JunkSizeRefused(bytes: -5)) { try lying.setJunk(absent, bytes: -5) }
        #expect(throws: LyingBlobStore.JunkSizeRefused(bytes: FileIntake.maxFileBytes + 1)) {
            try lying.setJunk(absent, bytes: FileIntake.maxFileBytes + 1)
        }
        #expect(lying.junk.isEmpty)
        try lying.setJunk(absent, bytes: 1)
        try lying.setJunk(absent, bytes: FileIntake.maxFileBytes)
        #expect(lying.junk == [absent: FileIntake.maxFileBytes], "a later size replaces the first")
    }

    @Test func clearedJunkIsHonestAgain() throws {
        let (inner, lying) = filled()
        let mine = BlobHash(of: held)
        try lying.setJunk(mine, bytes: 10)
        try lying.setJunk(absent, bytes: 10)
        lying.clearJunk(mine)
        lying.clearJunk(absent)
        #expect(lying.junk.isEmpty)
        #expect(lying.bytes(of: mine) == inner.bytes(of: mine) && lying.size(of: mine) == held.count)
        #expect(!lying.contains(absent) && lying.size(of: absent) == nil)
    }

    @Test func aWithheldBlobReadsAsGoneButStillHeld() {
        let (inner, lying) = filled()
        let mine = BlobHash(of: held)
        lying.withhold(mine)
        #expect(lying.withheld == [mine])
        #expect(lying.size(of: mine) == nil && lying.mime(of: mine) == nil)
        #expect(lying.read(mine, offset: 0, count: 10) == nil && lying.bytes(of: mine) == nil)
        #expect(lying.contains(mine) && lying.held(among: [mine]) == [mine], "never wanted again")
        #expect(lying.allHashes() == inner.allHashes() && lying.totalBytes(among: [mine]) == held.count, "the sweeps see it")
        #expect(lying.size(of: BlobHash(of: other)) == other.count, "only the hash withheld")

        lying.release(mine)
        #expect(lying.withheld.isEmpty && lying.bytes(of: mine) == held)
    }

    @Test func junkWinsOverWithheld() throws {
        let (_, lying) = filled()
        let mine = BlobHash(of: held)
        lying.withhold(mine)
        try lying.setJunk(mine, bytes: 50)
        #expect(lying.size(of: mine) == 50 && lying.read(mine, offset: 0, count: 50)?.count == 50)
        lying.clearJunk(mine)
        #expect(lying.size(of: mine) == nil, "withheld again once the junk is cleared")
    }

    @Test func writesGoToTheWrappedStoreWhateverIsSet() throws {
        let inner = MemoryBlobStore()
        let lying = LyingBlobStore(wrapping: inner)
        let hash = BlobHash(of: held)
        try lying.setJunk(hash, bytes: 10)
        #expect(lying.insert(held, hash: hash, mime: "image/png", storedAt: 5))
        #expect(!lying.insert(held, hash: hash, mime: "image/png", storedAt: 6), "held already")
        #expect(inner.bytes(of: hash) == held && inner.hashes(storedBefore: 6) == [hash])
        lying.remove(hash)
        #expect(!inner.contains(hash))
        #expect(lying.contains(hash), "the junk still says held")
    }

    @Test func storesOverSwapOnlyTheBlobsAndKeepTheUnit() throws {
        let base = MeshStores.inMemory()
        let (stores, lying) = LyingBlobStore.stores(over: base)
        #expect(stores.blobs === lying)
        #expect(stores.transactor === base.transactor && stores.custody === base.custody && stores.peers === base.peers)
        #expect(stores.ownProfile === base.ownProfile && stores.ratchet === base.ratchet && stores.groupRatchet === base.groupRatchet)
        #expect(stores.messages === base.messages && stores.conversations === base.conversations)
        #expect(stores.blocks === base.blocks && stores.groups === base.groups)

        let hash = BlobHash(of: held)
        try lying.setJunk(absent, bytes: 20)
        let undone = stores.transactor.atomically { () -> Int? in
            stores.blobs.insert(held, hash: hash, mime: "image/png", storedAt: 1)
            return nil
        }
        #expect(undone == .abandoned)
        #expect(!base.blobs.contains(hash), "the unit undid the write made through the wrapper")
        #expect(lying.junk == [absent: 20], "and left the switches as they were")
        _ = stores.transactor.atomically { () -> Int? in
            stores.blobs.insert(held, hash: hash, mime: "image/png", storedAt: 1)
            return 1
        }
        #expect(base.blobs.contains(hash))
    }
}
