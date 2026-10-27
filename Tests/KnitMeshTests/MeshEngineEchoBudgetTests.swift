import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// What a want made for an asker may cost through the engine (knit-ios #20, from knit-next's malicious-fork review, H3
/// and H2's prefix item), with a `TestPeer` playing the asker, the fork and the holder: the want set keeps our own, the
/// echo budget bounds the bytes held for others, an asker past its cap rotates echoes that stood a step, and a want of ours
/// makes an echo resumable. The sweep and the serve bound are ``MeshEngineEchoSweepTests``, the pure books
/// ``BlobEchoBoundsTests``.
@Suite struct MeshEngineEchoBudgetTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)

    private let photo: [UInt8] = Array("not really a jpeg, but bytes all the same".utf8)
    private var photoHash: BlobHash { BlobHash(of: photo) }
    private let capable = Capabilities.local.union(.blobHave)

    private func hash(_ index: Int) -> BlobHash {
        BlobHash(of: Array("blob \(index)".utf8))
    }

    private func shown(_ hash: BlobHash) -> Substring {
        hash.string.prefix(BlobExchange.shownHashCharacters)
    }

    /// What the log says became of each blob request for `hash`, in order.
    private func answers(_ fixture: EngineFixture, for hash: BlobHash) -> [String] {
        let prefix = "debug mesh blobreq \(hash.string.prefix(12)) from "
        return fixture.log.all.filter { $0.hasPrefix(prefix) }.compactMap { $0.split(separator: ": ", maxSplits: 1).last.map(String.init) }
    }

    /// `peer` answers every holder query the fixture wrote it, saying `state` of each hash in `of`, and nothing of the rest.
    private func answerQueries(_ fixture: EngineFixture, from peer: TestPeer, _ state: (BlobHash) -> BlobHolding?) throws {
        for query in fixture.transport.written(.blobHave) where query.to == peer.nodeId {
            let hashes = try BlobHaveContent(decoding: query.envelope.payload).hashes.compactMap(BlobHash.init)
            let items = hashes.compactMap { hash in state(hash).map { BlobHasItem(hash: hash.string, state: $0, size: 1000) } }
            fixture.deliver(peer.blobHas(items, re: query.envelope.id), from: peer)
        }
    }

    private func file(_ bytes: [UInt8], from peer: TestPeer) -> InboundFile {
        InboundFile(from: peer.nodeId, kind: .attachment, hash: BlobHash(of: bytes), mime: "image/jpeg", bytes: bytes)
    }

    // MARK: The want set

    @Test func aForksAsksPushNoWantOfOursOut() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        let ours = (0..<BlobExchange.maxWanted).map { index in
            BlobExchange.OwnWant(hash: hash(index), author: nil, reach: .own(until: nil, rederived: true))
        }
        fixture.engine.wantBlobs(ours)
        for index in 0..<300 {
            fixture.deliver(bob.blobRequest(for: hash(1000 + index).string, id: frameIdOf("fork-\(index)"), pull: 3), from: bob)
        }
        #expect(fixture.engine.blobExchange.wanted == ours.map(\.hash), "every want of ours still wanted")
        #expect(fixture.engine.blobCounts.echoesDeclined == 300)
        #expect(answers(fixture, for: hash(1000)) == ["not held; no echo (every want is ours)"])
        #expect(fixture.log.all.contains("debug mesh blob no-echo \(shown(hash(1000)))… for \(bob.nodeId) (every want is ours)"))
    }

    /// `peer` answers each holder query the fixture wrote it that `answered` has not seen, saying HAVE of `held` alone.
    private func answerOnce(
        _ fixture: EngineFixture, from peer: TestPeer, holding held: BlobHash, _ answered: inout Set<String>
    ) throws {
        for query in fixture.transport.written(.blobHave) where query.to == peer.nodeId && answered.insert(query.envelope.id).inserted {
            let hashes = try BlobHaveContent(decoding: query.envelope.payload).hashes
            let items = hashes.map { BlobHasItem(hash: $0, state: $0 == held.string ? .have : .notHeld, size: 41) }
            fixture.deliver(peer.blobHas(items, re: query.envelope.id), from: peer)
        }
    }

    /// The fetch asks of `peer` for the photo so far.
    private func photoFetches(_ fixture: EngineFixture, of peer: TestPeer) throws -> [Written] {
        try fixture.transport.written(.blobRequest).filter { written in
            try written.to == peer.nodeId && BlobRequestContent(decoding: written.envelope.payload).hash == photoHash.string
        }
    }

    /// blobs-reviewer's walk (round 2): a root re-asks its whole backlog of 41 in one order every cycle, the first 40 held
    /// nowhere in reach and the 41st by dave. Under a per-asker cap any rule over its slots is a cache smaller than the
    /// root's cycle, and the tail never gets an echo; here every ask makes one while the set has room, so the photo is
    /// fetched in the root's first cycle, one copy from dave and one on to the root, over six cycles, the root asking for
    /// it until it is served.
    @Test func aRootReaskingFortyOneInOneOrderHasItsLastFetchedInItsFirstCycle() throws {
        let fixture = EngineFixture(alice, configuration: MeshConfiguration(queriesBlobHolders: true))
        fixture.link(bob, dave, capabilities: capable)
        let asked = (0..<40).map(hash) + [photoHash]
        var answered: Set<String> = []
        var landedAtCycle: Int?
        for cycle in 0..<6 {
            // A root stops asking for what it was served.
            let backlog = fixture.transport.files.contains { $0.hash == photoHash } ? Array(asked.dropLast()) : asked
            for (index, hash) in backlog.enumerated() {
                fixture.deliver(bob.blobRequest(for: hash.string, id: frameIdOf("root-\(cycle)-\(index)"), pull: 3), from: bob)
            }
            try answerOnce(fixture, from: dave, holding: photoHash, &answered)
            if landedAtCycle == nil, try !photoFetches(fixture, of: dave).isEmpty {
                fixture.engine.receiveFile(file(photo, from: dave))
                landedAtCycle = cycle
            }
            fixture.advance(60_000)
        }
        #expect(landedAtCycle == 0, "fetched in the root's first cycle")
        #expect(try photoFetches(fixture, of: dave).count == 1, "one ask of the holder, so one copy from it")
        #expect(fixture.transport.files.filter { $0.hash == photoHash }.map(\.to) == [bob.nodeId], "one copy on to the root")
        #expect(fixture.engine.blobCounts.echoesDeclined == 0)
    }

    /// A fork asks for 300 fresh hashes every cycle while an honest root re-asks its 40 in one order, the 40th held by
    /// dave, into a set that already holds wants of ours. The fork's flood evicts its own echoes, never the root's while it
    /// holds more than the root, and never a want of ours; the root's live photo lands.
    @Test func aForkFloodingTheSetBesideAnHonestRootEvictsItsOwnAndTheRootsPhotoLands() throws {
        let fixture = EngineFixture(alice, configuration: MeshConfiguration(queriesBlobHolders: true))
        fixture.link(bob, carol, dave, capabilities: capable)
        let ours = (0..<30).map { index in
            BlobExchange.OwnWant(hash: hash(9000 + index), author: nil, reach: .own(until: nil, rederived: true))
        }
        fixture.engine.wantBlobs(ours)
        let rooted = (0..<39).map(hash) + [photoHash]
        var answered: Set<String> = []
        var landed = false
        let exchange = { fixture.engine.blobExchange }
        let share = { (asker: TestPeer) in exchange().wants.values.count { $0.echoFor == asker.nodeId } }
        for cycle in 0..<3 {
            let asks =
                rooted.enumerated().map { (carol, $1, "root-\(cycle)-\($0)") }
                + (0..<300).map { (bob, hash(10_000 * (cycle + 1) + $0), "fork-\(cycle)-\($0)") }
            for (asker, hash, id) in asks {
                let rootBefore = Set(rooted.filter { exchange().isEcho($0) })
                let (forkShare, rootShare) = (share(bob), share(carol))
                fixture.deliver(asker.blobRequest(for: hash.string, id: frameIdOf(id), pull: 3), from: asker)
                let lost = rootBefore.filter { !exchange().isWanted($0) && !fixture.stores.blobs.contains($0) }
                #expect(lost.isEmpty || forkShare + (asker == bob ? 1 : 0) <= rootShare + (asker == carol ? 1 : 0))
            }
            #expect(ours.allSatisfy { exchange().isWanted($0.hash) }, "no want of ours evicted")
            try answerOnce(fixture, from: dave, holding: photoHash, &answered)
            // The wait for the queries the fork and the root never answer.
            fixture.advance(BlobExchange.queryWaitMilliseconds)
            if !landed, try !photoFetches(fixture, of: dave).isEmpty {
                fixture.engine.receiveFile(file(photo, from: dave))
                landed = true
            }
            fixture.advance(60_000 - BlobExchange.queryWaitMilliseconds)
        }
        #expect(landed && fixture.stores.blobs.contains(photoHash), "the root's live photo landed")
        #expect(share(carol) == rooted.count - 1, "every other echo of the root's stands")
    }

    /// A want dropped for a full set withdraws our ask on the holder it stood on (knit-next ADR 2026-10.nsr7), so the copy
    /// it queued for us is not sent for nothing.
    @Test func anEchoEvictedForAFullSetWithdrawsItsStandingAsk() throws {
        let fixture = EngineFixture(alice, configuration: MeshConfiguration(queriesBlobHolders: true))
        fixture.link(bob, dave, capabilities: capable)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-1"), pull: 3), from: bob)
        let query = try #require(fixture.transport.written(.blobHave).last { $0.to == dave.nodeId })
        fixture.deliver(dave.blobHas([BlobHasItem(hash: photoHash.string, state: .have, size: 41)], re: query.envelope.id), from: dave)
        #expect(fixture.transport.written(.blobRequest).contains { $0.to == dave.nodeId })
        fixture.transport.clear()
        let ours = (0..<BlobExchange.maxWanted).map { index in
            BlobExchange.OwnWant(hash: hash(index), author: nil, reach: .own(until: nil, rederived: true))
        }
        fixture.engine.wantBlobs(ours)
        #expect(!fixture.engine.blobExchange.isWanted(photoHash))
        let cancels = try fixture.transport.written(.blobCancel).map { (try BlobCancelContent(decoding: $0.envelope.payload).hash, $0.to) }
        #expect(cancels.contains { $0.0 == photoHash.string && $0.1 == dave.nodeId })
    }

    // MARK: The echo budget

    /// knit-next's fork review H3, in full size: a fork asks for 256 hashes with `pull: 3`, every one an echo, then at the
    /// next cycle says it holds sixteen of them and streams junk of the largest size a link keeps under each, asked for or
    /// not. The budget lets fifteen fetches go and holds the rest back; the sixteenth file lands for nothing and is
    /// refused. Held bytes no row names stay within the budget, and a blob held is still served to anyone.
    @Test func aForkServingJunkForItsAsksFillsNoMoreThanTheEchoBudget() throws {
        let fixture = EngineFixture(alice, configuration: MeshConfiguration(queriesBlobHolders: true))
        fixture.link(bob, capabilities: capable)
        let size = FileIntake.maxFileBytes
        let junk: (Int) -> [UInt8] = { index in
            var bytes = [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: size)
            bytes.replaceSubrange(0..<8, with: withUnsafeBytes(of: UInt64(index)) { Array($0) })
            return bytes
        }
        let echoed = (0..<16).map { BlobHash(of: junk($0)) }
        let asked = echoed + (echoed.count..<BlobExchange.maxWanted).map(hash)
        for (index, hash) in asked.enumerated() {
            fixture.deliver(bob.blobRequest(for: hash.string, id: frameIdOf("fork-\(index)"), pull: 3), from: bob)
        }
        #expect(fixture.engine.blobExchange.wanted == asked)
        #expect(fixture.engine.blobCounts.echoesDeclined == 0)

        // The next cycle queries the fork, which says it holds the sixteen.
        fixture.transport.clear()
        fixture.advance(60_000)
        let junkHashes = Set(echoed)
        try answerQueries(fixture, from: bob) { junkHashes.contains($0) ? .have : .notHeld }
        let fetched = Set(
            try fixture.transport.written(.blobRequest).map { try BlobRequestContent(decoding: $0.envelope.payload).hash }
                .filter { BlobHash($0).map(junkHashes.contains) == true })
        let fits = Int(BlobExchange.echoBudgetBytes / Int64(size))
        #expect(fetched.count == fits, "each fetch reserves a whole file of the budget")
        #expect(fixture.engine.blobCounts.echoFetchesHeld > 0)

        // It streams all sixteen.
        for index in echoed.indices {
            fixture.engine.receiveFile(file(junk(index), from: bob))
        }
        let held = echoed.filter { fixture.stores.blobs.contains($0) }
        #expect(held.count == fits)
        #expect(Int64(fixture.stores.blobs.totalBytes(among: Set(echoed))) <= BlobExchange.echoBudgetBytes)
        #expect(fixture.engine.blobCounts.echoFilesRefused == echoed.count - fits)
        let refused = try #require(echoed.first { !held.contains($0) })
        #expect(fixture.log.all.contains("info mesh file \(refused.string.prefix(12)) from \(bob.nodeId) is past the echo budget; dropped"))
        #expect(!fixture.engine.blobExchange.isWanted(refused), "its want went with it")

        // Asked again before the next sweep, it is no echo: the bytes would only be refused again.
        fixture.deliver(bob.blobRequest(for: refused.string, id: frameIdOf("fork-again"), pull: 3), from: bob)
        #expect(answers(fixture, for: refused).last == "not held; no echo (over budget)")
        // What is held is served to anyone, past any budget.
        fixture.link(carol)
        fixture.transport.clear()
        fixture.deliver(carol.blobRequest(for: held[0].string, id: frameIdOf("carol-held"), pull: 3), from: carol)
        #expect(fixture.transport.files.map(\.hash) == [held[0]])
    }

    /// A root with many dead photos and one live one, bridged through us: the dead echoes ask nobody that holds them, so
    /// they reserve nothing, and the live one is fetched and served on although twenty-one echoes of whole files would not fit.
    @Test func aRootsDeadEchoesReserveNothingSoItsLivePhotoStillComesThrough() throws {
        let fixture = EngineFixture(alice, configuration: MeshConfiguration(queriesBlobHolders: true))
        fixture.link(bob, dave, capabilities: capable)
        let dead = (0..<20).map(hash)
        let order = Array(dead.prefix(15)) + [photoHash] + dead.suffix(5)
        for (index, hash) in order.enumerated() {
            fixture.deliver(bob.blobRequest(for: hash.string, id: frameIdOf("root-\(index)"), pull: 3), from: bob)
        }
        #expect(fixture.engine.blobExchange.wanted == order)
        try answerQueries(fixture, from: dave) { $0 == photoHash ? .have : .notHeld }
        let fetches = fixture.transport.written(.blobRequest).filter { $0.to == dave.nodeId }
        #expect(try fetches.map { try BlobRequestContent(decoding: $0.envelope.payload).hash }.contains(photoHash.string))
        #expect(fixture.engine.blobCounts.echoFetchesHeld == 0)
        #expect(
            fixture.engine.blobExchange.echoReservedBytes(arriving: [], excluding: nil) == Int64(FileIntake.maxFileBytes),
            "the live one alone")

        fixture.engine.receiveFile(file(photo, from: dave))
        #expect(fixture.stores.blobs.contains(photoHash))
        fixture.clock.advance(BlobExchange.serveMemoMilliseconds)
        fixture.transport.clear()
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("root-again"), pull: 3), from: bob)
        #expect(fixture.transport.files.map(\.to) == [bob.nodeId], "served on to the root")
    }

    // MARK: Resumable

    @Test func aWantOfOursForAnEchoMakesItResumableInTheNextAcceptCall() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-1"), pull: 3), from: bob)
        let calls = fixture.transport.acceptCalls.count
        #expect(fixture.transport.accepted == [photoHash] && fixture.transport.resumable.isEmpty)
        fixture.engine.wantBlob(photoHash, author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: false))
        #expect(fixture.transport.acceptCalls.count == calls + 1, "the keys are the same; only what is resumable moved")
        #expect(fixture.transport.acceptCalls.last?.keys == [photoHash] && fixture.transport.acceptCalls.last?.resumable == [photoHash])

        // An echo whose bytes are already streaming in is taken over all the same, by the re-arm that skips it.
        let other = hash(1)
        fixture.deliver(bob.blobRequest(for: other.string, id: frameIdOf("breq-2"), pull: 3), from: bob)
        fixture.transport.arrivingFileKeys = [other]
        fixture.engine.wantBlobs([BlobExchange.OwnWant(hash: other, author: nil, reach: .own(until: nil, rederived: true))])
        #expect(fixture.transport.resumable == [photoHash, other])
    }
}
