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

    @Test func aPhotoWantIsPhotoOnlyUntilAnotherWantOfOursRecordsIt() {
        var row = exchange()
        #expect(row.isPhotoOnly(photo) && row.photoOnlyWanted == [photo])
        _ = row.recordWant(photo, now: 1, wall: wallAt(1), author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: true))
        #expect(!row.isPhotoOnly(photo), "a message's want of the same blob: the attachment's limit wins")
        _ = row.recordWant(
            photo, now: 2, wall: wallAt(2), author: bob, via: nil, asker: nil, reach: .own(until: nil, rederived: false), kind: .photo)
        #expect(!row.isPhotoOnly(photo), "cleared for the want's life")

        var asked = exchange()
        _ = asked.recordWant(photo, now: 1, wall: wallAt(1), author: nil, via: nil, asker: carol, reach: .asked(pull: 3, until: nil))
        #expect(asked.isPhotoOnly(photo), "a neighbour's ask moves no ceiling (BlobExchange.kt:116)")
        _ = asked.recordWant(
            photo, now: 2, wall: wallAt(2), author: bob, via: nil, asker: nil, reach: .own(until: nil, rederived: false), kind: .photo)
        #expect(asked.isPhotoOnly(photo), "two photo wants keep the photo's ceiling")

        let attachment = exchange(kind: .attachment)
        #expect(!attachment.isPhotoOnly(photo))
        var echo = BlobExchange(queriesHolders: true)
        _ = echo.recordWant(
            photo, now: 0, wall: wallAt(0), author: nil, via: nil, asker: carol, reach: .asked(pull: 3, until: nil), kind: .photo)
        #expect(!echo.isPhotoOnly(photo), "an echo is its asker's, never photo-only")
    }

    @Test func aPhotoWantOnAWantOnlyANeighboursAskMadeTakesThePhotoCeiling() {
        // BlobHolderQueryTest's, by name (knit-next `a0b52f865`): `mergeCeiling`'s `!w.ownWant -> ceiling`.
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, wall: wallAt(0), author: nil, via: nil, asker: bob, reach: .asked(pull: 3, until: nil))
        #expect(exchange.isWanted(photo) && !exchange.isPhotoOnly(photo), "a pull-through opens the want, uncapped")
        _ = exchange.recordWant(
            photo, now: 1, wall: wallAt(1), author: carol, via: nil, asker: nil, reach: .own(until: nil, rederived: false), kind: .photo)
        #expect(exchange.isPhotoOnly(photo) && exchange.photoOnlyWanted == [photo], "our first want sets its own ceiling")
        _ = exchange.recordWant(photo, now: 2, wall: wallAt(2), author: nil, via: nil, asker: bob, reach: .asked(pull: 3, until: nil))
        #expect(exchange.isPhotoOnly(photo), "a neighbour's ask still lifts nothing")
        _ = exchange.recordWant(
            photo, now: 3, wall: wallAt(3), author: carol, via: nil, asker: nil, reach: .own(until: nil, rederived: true))
        #expect(!exchange.isPhotoOnly(photo), "an attachment want of ours does")
    }

    @Test func anEchoOurPhotoWantTouchesLeavesAMarkedHolderOut() {
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, wall: wallAt(0), author: nil, via: nil, asker: carol, reach: .asked(pull: 3, until: nil))
        exchange.photoRefusals.mark(photo, holder: bob) // its stream passed the ceiling earlier this session
        _ = exchange.recordWant(
            photo, now: 1, wall: wallAt(1), author: dave, via: nil, asker: nil, reach: .own(until: nil, rederived: false), kind: .photo)
        #expect(exchange.isPhotoOnly(photo))
        let linked = capable(bob, carol)
        for now: Int64 in [1, 60_000, 120_000] {
            let plan = step(&exchange, linked, at: now)
            #expect(!plan.query.contains(bob) && !plan.asks.map(\.to).contains(bob), "at \(now)")
        }
    }

    @Test func aPromotedEchoTakesOurPhotoWantsCeiling() {
        // Promotion is this port's alone and no want of ours recording (Kotlin's own want returns at on-the-way, `:295`).
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, wall: wallAt(0), author: nil, via: nil, asker: carol, reach: .asked(pull: 3, until: nil))
        #expect(exchange.promote(photo) && !exchange.isEcho(photo))
        _ = exchange.recordWant(
            photo, now: 1, wall: wallAt(1), author: dave, via: nil, asker: nil, reach: .own(until: nil, rederived: false), kind: .photo)
        #expect(exchange.isPhotoOnly(photo))
    }

    @Test func aWantMadeAfreshFromZeroKeepsTheAttachmentsCeiling() {
        // `reaskFromZero`'s fresh want is ours, an attachment's (`BlobExchange.kt:2151`): a photo want after it lifts nothing.
        var exchange = BlobExchange(queriesHolders: true)
        exchange.restartFromZero(photo, failing: bob, now: 0, wall: wallAt(0))
        #expect(exchange.isWanted(photo) && !exchange.isPhotoOnly(photo))
        _ = exchange.recordWant(
            photo, now: 1, wall: wallAt(1), author: dave, via: nil, asker: nil, reach: .own(until: nil, rederived: false), kind: .photo)
        #expect(!exchange.isPhotoOnly(photo))
    }

    @Test func aRefusedPhotoWantLeavesAStandingEchoAlone() {
        // `want` returns before `recordWant` for a photo want of a hash refused this session (`BlobExchange.kt:289`).
        var exchange = BlobExchange(queriesHolders: true)
        exchange.refusePhoto(photo)
        _ = exchange.recordWant(photo, now: 0, wall: wallAt(0), author: nil, via: nil, asker: carol, reach: .asked(pull: 3, until: nil))
        _ = exchange.recordWant(
            photo, now: 1, wall: wallAt(1), author: dave, via: nil, asker: nil, reach: .own(until: nil, rederived: false), kind: .photo)
        #expect(!exchange.isPhotoOnly(photo) && exchange.isEcho(photo), "still carol's echo, at the attachment's ceiling")
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
        #expect(exchange.overPhotoCeiling(photo, from: bob) == .init(cancels: [], isNew: true), "never asked, so nothing to withdraw")
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
        #expect(exchange.overPhotoCeiling(photo, from: bob)?.cancels == [bob])
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

    @Test func aHolderPassedOverThatAsksForTheHashIsNotAskedAgain() {
        var exchange = exchange(author: dave)
        let linked = capable(bob)
        _ = step(&exchange, linked, at: 0)
        answer(&exchange, bob, size: 4000, at: 100)
        #expect(step(&exchange, linked, at: 100).asks == [BlobExchange.Ask(to: bob, line: .fetch)])
        #expect(exchange.overPhotoCeiling(photo, from: bob)?.cancels == [bob])
        // Bob asks us for the hash himself: an ask is no want of ours, so the ceiling stands (`BlobExchange.kt:2211`).
        _ = exchange.recordWant(photo, now: 200, wall: wallAt(200), author: nil, via: nil, asker: bob, reach: .asked(pull: 3, until: nil))
        #expect(exchange.isPhotoOnly(photo))
        var now: Int64 = 200
        for _ in 0..<3 {
            now += 60_000
            let plan = step(&exchange, linked, at: now)
            #expect(plan.query.isEmpty && plan.asks.isEmpty, "a new cycle at each re-offer, his ask cleared, leaves him out")
        }
        #expect(exchange.isPhotoOnly(photo))
    }

    @Test func aPassedOverHolderIsAskedAgainOnceTheWantIsNoLongerPhotoOnly() {
        var exchange = exchange(author: dave)
        let linked = capable(bob)
        _ = step(&exchange, linked, at: 0)
        _ = exchange.overPhotoCeiling(photo, from: bob)
        _ = exchange.recordWant(photo, now: 1, wall: wallAt(1), author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: true))
        #expect(step(&exchange, linked, at: 60_000).query == [bob], "the attachment's limit: its copy fits")
        _ = exchange.recordWant(photo, now: 2, wall: wallAt(2), author: nil, via: nil, asker: carol, reach: .asked(pull: 3, until: nil))
        #expect(!exchange.isPhotoOnly(photo), "an ask after it restores nothing")
    }

    @Test func aMarkedHolderIsNotAskedAgainByTheReaskRoundOrANewWantButAnAttachmentWantLiftsTheCeiling() {
        // BlobHolderQueryTest's, by name (knit-next `a0b52f865`).
        var exchange = BlobExchange(queriesHolders: true)
        exchange.photoRefusals.mark(photo, holder: bob) // its stream passed the ceiling earlier this session
        let own = BlobExchange.Reach.own(until: nil, rederived: false)
        _ = exchange.recordWant(photo, now: 0, wall: wallAt(0), author: carol, via: nil, asker: nil, reach: own, kind: .photo)
        let linked = capable(bob)
        var plans = [step(&exchange, linked, at: 0), step(&exchange, linked, at: 60_000)]
        _ = exchange.recordWant(photo, now: 60_001, wall: wallAt(60_001), author: carol, via: nil, asker: nil, reach: own, kind: .photo)
        plans.append(step(&exchange, linked, at: 120_000))
        #expect(plans.allSatisfy { $0.query.isEmpty && $0.asks.isEmpty }, "never queried, never asked")
        #expect(exchange.isWanted(photo), "the want stands for an unmarked holder")
        _ = exchange.recordWant(photo, now: 120_001, wall: wallAt(120_001), author: carol, via: nil, asker: nil, reach: own)
        #expect(!exchange.isPhotoOnly(photo))
        #expect(step(&exchange, linked, at: 180_000).query == [bob], "the larger ceiling wins, marks and all")
    }

    @Test func aHolderPassedOverStaysPassedOverWhenTheSessionsBoundedMarkIsDropped() {
        // BlobHolderQueryTest's, by name (knit-next `a0b52f865`): the want's own `passedOver` outlives the session's mark.
        var exchange = BlobExchange(queriesHolders: true)
        exchange.photoRefusals.mark(photo, holder: bob)
        _ = exchange.recordWant(
            photo, now: 0, wall: wallAt(0), author: carol, via: nil, asker: nil, reach: .own(until: nil, rederived: false), kind: .photo)
        let linked = capable(bob)
        #expect(step(&exchange, linked, at: 0).query.isEmpty)
        for index in 0..<PhotoRefusals.maxEntries {
            exchange.photoRefusals.mark(BlobHash(of: Array("other \(index)".utf8)), holder: dave)
        }
        #expect(!exchange.photoRefusals.isMarked(photo, holder: bob), "the session's bounded set dropped it")
        for now: Int64 in [60_000, 120_000] {
            let plan = step(&exchange, linked, at: now)
            #expect(plan.query.isEmpty && plan.asks.isEmpty, "never queried, never asked, at \(now)")
        }
        // Kotlin counts where `passOver` newly inserts a holder (`BlobExchange.kt:505`, `:514-516`): the mark here was made
        // straight into the session's set, so the want's copy of it is the one count, and the dropped mark adds none.
        #expect(exchange.counts.photosOverCeiling == 1, "the copy counts once")
    }

    @Test func aWantPassesOverAtMostSixtyFourHolders() {
        var exchange = exchange(author: dave)
        let holders = (0...BlobExchange.maxPassedOver).map { TestPeer(seed: 10 + $0).nodeId }
        let passes = holders.map { exchange.overPhotoCeiling(photo, from: $0) }
        #expect(exchange.wants[photo]?.passedOver == Set(holders.prefix(BlobExchange.maxPassedOver)))
        // The bound keeps the 65th out, so it counts nothing (`BlobExchange.kt:505`); it is still marked and failed.
        #expect(passes.map { $0?.isNew } == Array(repeating: true, count: BlobExchange.maxPassedOver) + [false])
        #expect(exchange.counts.photosOverCeiling == BlobExchange.maxPassedOver)
        #expect(exchange.photoRefusals.isMarked(photo, holder: holders[BlobExchange.maxPassedOver]))
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
        #expect(exchange.overPhotoCeiling(photo, from: bob)?.cancels == [bob])
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

/// A newly passed-over holder's ask, apart from the suite's body for its length.
extension BlobPhotoCeilingTests {
    @Test func anEchoOurPhotoWantTouchesWithdrawsItsAskOnAMarkedHolder() {
        // Kotlin's `passOver` withdraws a holder it newly passes over with our ask on it (`BlobExchange.kt:506-510`).
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, wall: wallAt(0), author: nil, via: nil, asker: carol, reach: .asked(pull: 3, until: nil))
        let linked = capable(bob, carol)
        _ = step(&exchange, linked, at: 0)
        answer(&exchange, bob, size: 4000, at: 100)
        #expect(step(&exchange, linked, at: 100).asks == [BlobExchange.Ask(to: bob, line: .fetch)], "the echo asks bob")
        exchange.photoRefusals.mark(photo, holder: bob) // an earlier photo want of the hash passed bob over
        _ = exchange.recordWant(
            photo, now: 200, wall: wallAt(200), author: dave, via: nil, asker: nil, reach: .own(until: nil, rederived: false), kind: .photo)
        let plan = step(&exchange, linked, at: 200)
        #expect(plan.cancels == [bob], "its ask on bob is withdrawn")
        #expect(step(&exchange, linked, at: 300).cancels.isEmpty, "once")
    }
}

/// A holder is counted, and logged, once per want: where it is newly added to the want's ``BlobExchange/Want/passedOver``,
/// whichever signal marked it (`BlobExchange.kt:505`, `:514-516` at knit-next `a0b52f865`).
extension BlobPhotoCeilingTests {
    /// The `passOver` line for `holder`, as a step's notes carry it.
    private func markedLine(_ holder: NodeId) -> String {
        "blob photo \(photo.string.prefix(BlobExchange.shownHashCharacters))… from \(holder) marked earlier this session: passed over"
    }

    @Test func aSecondSignalFromAHolderAlreadyPassedOverCountsNothing() {
        // Trial run 20261031-030424: a size claim, then a crossing stream's header from the same holder, counted two.
        var exchange = exchange(author: dave)
        let linked = capable(bob)
        _ = step(&exchange, linked, at: 0)
        answer(&exchange, bob, size: 4000, at: 100)
        #expect(step(&exchange, linked, at: 100).asks == [BlobExchange.Ask(to: bob, line: .fetch)])
        #expect(exchange.overPhotoCeiling(photo, from: bob) == .init(cancels: [bob], isNew: true))
        #expect(exchange.overPhotoCeiling(photo, from: bob) == .init(cancels: [], isNew: false), "already withdrawn, not new")
        #expect(exchange.counts.photosOverCeiling == 1)
        let plan = step(&exchange, linked, at: 200)
        #expect(plan.cancels.isEmpty && !plan.notes.contains(markedLine(bob)), "the step's copy finds it passed over already")
        #expect(exchange.counts.photosOverCeiling == 1)
    }

    @Test func aSessionMarkCountsOncePerNewWantOfTheHash() {
        // Kotlin's new want of the hash has a fresh `passedOver`, so its first step counts the session's marks again.
        var exchange = BlobExchange(queriesHolders: true)
        exchange.photoRefusals.mark(photo, holder: bob)
        let own = BlobExchange.Reach.own(until: nil, rederived: false)
        _ = exchange.recordWant(photo, now: 0, wall: wallAt(0), author: dave, via: nil, asker: nil, reach: own, kind: .photo)
        let linked = capable(bob, carol)
        #expect(step(&exchange, linked, at: 0).notes.filter { $0 == markedLine(bob) }.count == 1)
        #expect(exchange.counts.photosOverCeiling == 1)
        // Re-wanted while it stands, and stepped again: the want's own set already has bob.
        _ = exchange.recordWant(photo, now: 1, wall: wallAt(1), author: dave, via: nil, asker: nil, reach: own, kind: .photo)
        #expect(!step(&exchange, linked, at: 60_000).notes.contains(markedLine(bob)))
        #expect(exchange.counts.photosOverCeiling == 1, "a re-want while the want stands counts nothing more")
        // Forgotten, then wanted afresh: a new want counts the marked holder again.
        exchange.forget(photo)
        _ = exchange.recordWant(photo, now: 60_001, wall: wallAt(60_001), author: dave, via: nil, asker: nil, reach: own, kind: .photo)
        #expect(step(&exchange, linked, at: 60_001).notes.filter { $0 == markedLine(bob) }.count == 1)
        #expect(exchange.counts.photosOverCeiling == 2)
        // Obtained, then wanted afresh: the same.
        _ = exchange.obtained(photo, from: carol)
        _ = exchange.recordWant(photo, now: 60_002, wall: wallAt(60_002), author: dave, via: nil, asker: nil, reach: own, kind: .photo)
        _ = step(&exchange, linked, at: 60_002)
        #expect(exchange.counts.photosOverCeiling == 3)
    }

    @Test func aWantsCopyOfTheSessionsMarksCountsAtMostSixtyFour() {
        var exchange = BlobExchange(queriesHolders: true)
        let holders = (0...BlobExchange.maxPassedOver).map { TestPeer(seed: 10 + $0).nodeId }
        for holder in holders {
            exchange.photoRefusals.mark(photo, holder: holder)
        }
        _ = exchange.recordWant(
            photo, now: 0, wall: wallAt(0), author: dave, via: nil, asker: nil, reach: .own(until: nil, rederived: false), kind: .photo)
        let plan = step(&exchange, capable(carol), at: 0)
        #expect(exchange.counts.photosOverCeiling == BlobExchange.maxPassedOver, "the 65th, kept out by the bound, counts nothing")
        #expect(plan.notes.filter { $0.hasSuffix("marked earlier this session: passed over") }.count == BlobExchange.maxPassedOver)
        #expect(!plan.notes.contains(markedLine(holders[BlobExchange.maxPassedOver])))
        #expect(step(&exchange, capable(carol), at: 60_000).notes.allSatisfy { !$0.hasSuffix("passed over") }, "once")
        #expect(exchange.counts.photosOverCeiling == BlobExchange.maxPassedOver)
    }

    @Test func aWantThatIsNotPhotoOnlyCopiesNoMarkAndCountsNothing() {
        var exchange = exchange(author: dave, kind: .attachment)
        exchange.photoRefusals.mark(photo, holder: bob)
        let plan = step(&exchange, capable(bob), at: 0)
        #expect(plan.query == [bob] && !plan.notes.contains(markedLine(bob)))
        #expect(exchange.wants[photo]?.passedOver.isEmpty == true && exchange.counts.photosOverCeiling == 0)
    }
}
