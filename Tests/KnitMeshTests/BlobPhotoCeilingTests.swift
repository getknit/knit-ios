import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// The profile photo's ceiling in the blob exchange (ADR 2026-10.r88m, contract `profile-door-cap` section 6): a want made
/// only for a photo, a holder past the ceiling passed over for the session, the author included, and a held copy over it
/// refusing the hash.
@Suite struct BlobPhotoCeilingTests {
    private let bob = TestPeer(seed: 2).nodeId
    private let carol = TestPeer(seed: 3).nodeId
    private let dave = TestPeer(seed: 4).nodeId
    private let photo = BlobHash(of: Array("a photo".utf8))
    private let tooLarge = Int64(FileIntake.maxAvatarBytes) + 1

    private func capable(_ ids: NodeId...) -> [BlobExchange.Candidate] {
        ids.map { BlobExchange.Candidate(id: $0, streaming: false, capable: true) }
    }

    /// An exchange wanting the photo of `author`'s profile, of `kind`.
    private func exchange(author: NodeId? = nil, kind: BlobExchange.WantKind = .photo) -> BlobExchange {
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(
            photo, now: 0, wall: wallAt(0), author: author, via: nil, asker: nil, reach: .own(until: nil, rederived: false), kind: kind)
        return exchange
    }

    private func step(_ exchange: inout BlobExchange, _ linked: [BlobExchange.Candidate], at now: Int64) -> BlobExchange.Plan {
        exchange.decide(photo, among: linked, now: now, wall: wallAt(now))
    }

    private func answer(_ exchange: inout BlobExchange, _ peer: NodeId, size: Int64, load: Int = 0, at now: Int64) {
        let item = BlobHasItem(hash: photo.string, state: .have, size: size)
        _ = exchange.recordAnswers(BlobHasContent(items: [item], load: load), from: peer, now: now)
    }

    // MARK: The want's kind

    @Test func aPhotoWantIsPhotoOnlyUntilAnythingElseRecordsIt() {
        var row = exchange()
        #expect(row.isPhotoOnly(photo) && row.photoOnlyWanted == [photo])
        _ = row.recordWant(photo, now: 1, wall: wallAt(1), author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: true))
        #expect(!row.isPhotoOnly(photo), "a message's want of the same blob: the attachment's limit wins")
        _ = row.recordWant(
            photo, now: 2, wall: wallAt(2), author: bob, via: nil, asker: nil, reach: .own(until: nil, rederived: false), kind: .photo)
        #expect(!row.isPhotoOnly(photo), "cleared for the want's life")

        var echoed = exchange()
        _ = echoed.recordWant(photo, now: 1, wall: wallAt(1), author: nil, via: nil, asker: carol, reach: .asked(pull: 3, until: nil))
        #expect(!echoed.isPhotoOnly(photo), "an asker's ask on it")

        let attachment = exchange(kind: .attachment)
        #expect(!attachment.isPhotoOnly(photo))
        var echo = BlobExchange(queriesHolders: true)
        _ = echo.recordWant(
            photo, now: 0, wall: wallAt(0), author: nil, via: nil, asker: carol, reach: .asked(pull: 3, until: nil), kind: .photo)
        #expect(!echo.isPhotoOnly(photo), "an echo is its asker's, never photo-only")
    }

    @Test func anAttachmentWantIgnoresBothSignals() {
        var exchange = exchange(author: bob, kind: .attachment)
        #expect(exchange.overPhotoCeiling(photo, from: carol) == nil)
        #expect(exchange.overPhotoCeiling(photo, from: bob) == nil)
        #expect(exchange.isWanted(photo) && !exchange.photoRefusals.isMarked(photo, holder: carol) && !exchange.isPhotoRefused(photo))
        #expect(exchange.counts.photosOverCeiling == 0)
    }

    // MARK: A holder that is not the author

    @Test func aHolderClaimingTooMuchIsPassedOverAndTheOtherIsAsked() {
        var exchange = exchange(author: dave)
        let linked = capable(bob, carol)
        _ = step(&exchange, linked, at: 0)
        answer(&exchange, bob, size: tooLarge, at: 100)
        #expect(exchange.overPhotoCeiling(photo, from: bob)?.isEmpty == true, "never asked, so nothing to withdraw")
        answer(&exchange, carol, size: 4000, at: 200)
        let plan = step(&exchange, linked, at: 200)
        #expect(plan.asks == [BlobExchange.Ask(to: carol, line: .fetch)])
        #expect(exchange.isWanted(photo) && exchange.photoRefusals.isMarked(photo, holder: bob))
        #expect(exchange.counts.photosOverCeiling == 1)
    }

    @Test func aHolderPassedOverIsNeverQueriedOrAskedAgainThisSession() {
        var exchange = exchange(author: dave)
        let linked = capable(bob)
        _ = step(&exchange, linked, at: 0)
        answer(&exchange, bob, size: 4000, at: 100)
        let asked = step(&exchange, linked, at: 100)
        #expect(asked.asks == [BlobExchange.Ask(to: bob, line: .fetch)])
        // It streams past the ceiling: its ask is withdrawn, and the fetch on it ends.
        #expect(exchange.overPhotoCeiling(photo, from: bob) == [bob])
        var now: Int64 = 1000
        for _ in 0..<3 {
            now += 60_000
            let plan = step(&exchange, linked, at: now)
            #expect(plan.query.isEmpty && plan.asks.isEmpty, "a new cycle at each re-offer leaves it out")
        }
        // A new want of the same hash, after this one is forgotten, leaves it out too.
        exchange.forget(photo)
        _ = exchange.recordWant(
            photo, now: now, wall: wallAt(now), author: dave, via: nil, asker: nil, reach: .own(until: nil, rederived: true), kind: .photo)
        #expect(step(&exchange, linked, at: now).query.isEmpty)
        // Relinked under the same node id, it is still the same holder.
        exchange.linked([bob])
        #expect(step(&exchange, linked, at: now + 1).query.isEmpty)
    }

    @Test func aPassedOverHolderIsAskedAgainOnceTheWantIsNoLongerPhotoOnly() {
        var exchange = exchange(author: dave)
        let linked = capable(bob)
        _ = step(&exchange, linked, at: 0)
        _ = exchange.overPhotoCeiling(photo, from: bob)
        _ = exchange.recordWant(photo, now: 1, wall: wallAt(1), author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: true))
        #expect(step(&exchange, linked, at: 60_000).query == [bob], "the attachment's limit: its copy fits")
    }

    // MARK: The author

    @Test func theAuthorsCopyPassesItOverLikeAnyHolderAndTheWantGoesOn() {
        // Contract revision 5: the author is whoever advertised the hash, so its signal refuses nothing outright.
        var exchange = exchange(author: bob)
        let linked = capable(bob, carol)
        _ = step(&exchange, linked, at: 0)
        answer(&exchange, carol, size: 4000, load: 5, at: 100)
        answer(&exchange, bob, size: 4000, at: 100)
        let plan = step(&exchange, linked, at: 100)
        #expect(plan.asks == [BlobExchange.Ask(to: bob, line: .fetch)])
        #expect(exchange.overPhotoCeiling(photo, from: bob) == [bob])
        #expect(exchange.isWanted(photo) && !exchange.isPhotoRefused(photo) && exchange.photoRefusals.isMarked(photo, holder: bob))
        #expect(step(&exchange, linked, at: 200).asks == [BlobExchange.Ask(to: carol, line: .fetch)], "on to the other holder")
    }

    @Test func aHeldCopyOverTheCeilingRefusesTheHashUntilANewSession() {
        // Only held bytes prove the size: the hash is refused as a photo, and no photo want of it is recorded again.
        var exchange = BlobExchange(queriesHolders: true)
        exchange.refusePhoto(photo)
        _ = exchange.recordWant(
            photo, now: 0, wall: wallAt(0), author: bob, via: nil, asker: nil, reach: .own(until: nil, rederived: true), kind: .photo)
        #expect(!exchange.isWanted(photo), "never wanted again as a photo this session")
        _ = exchange.recordWant(photo, now: 1, wall: wallAt(1), author: nil, via: nil, asker: carol, reach: .asked(pull: 3, until: nil))
        #expect(exchange.isWanted(photo), "an asker's echo is its own")
        exchange.forgetPhotoRefusals()
        #expect(!exchange.isPhotoRefused(photo), "a new session")
    }

    // MARK: The bound

    @Test func theRefusalsKeepTheirNewestThousandAndTwentyFour() {
        var refusals = PhotoRefusals()
        let hashes = (0...PhotoRefusals.maxEntries).map { BlobHash(of: Array("photo \($0)".utf8)) }
        for hash in hashes {
            refusals.mark(hash, holder: bob)
            refusals.refuse(hash)
        }
        #expect(marked(refusals) == PhotoRefusals.maxEntries && refused(refusals) == PhotoRefusals.maxEntries)
        #expect(!refusals.isMarked(hashes[0], holder: bob) && !refusals.isRefused(hashes[0]), "the oldest went first")
        #expect(refusals.isMarked(hashes[1], holder: bob) && refusals.isRefused(hashes[PhotoRefusals.maxEntries]))
        refusals.mark(hashes[5], holder: bob)
        refusals.refuse(hashes[5])
        #expect(refused(refusals) == PhotoRefusals.maxEntries, "a hash refused again is one hash")
        #expect(marked(refusals) == PhotoRefusals.maxEntries, "a pair marked again is one pair")

        // How many of `hashes` are marked against bob, and how many refused.
        func marked(_ refusals: PhotoRefusals) -> Int { hashes.count { refusals.isMarked($0, holder: bob) } }
        func refused(_ refusals: PhotoRefusals) -> Int { hashes.count { refusals.isRefused($0) } }
    }
}
