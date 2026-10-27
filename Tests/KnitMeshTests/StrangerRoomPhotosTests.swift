import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The bound on strangers' photos in the room (knit-ios #21, the maintainer's decision): a stranger's newest eight, and of
/// those the newest 32 from all strangers, ranked by `sentAt` and then the id's bytes; known senders exempt. A photo it
/// leaves out is neither wanted nor named, so it is swept and never wanted again.
@Suite struct StrangerRoomPhotosTests {
    private let alice = TestPeer(seed: 1)
    private let thirtyOneMinutes: Int64 = 31 * 60_000

    private func row(_ id: String, from sender: TestPeer, at sentAt: Int64, mime: String? = "image/jpeg") -> AttachmentRow {
        row(id, from: sender, at: sentAt, mime: mime, in: Conversations.nearby)
    }

    private func row(_ id: String, from sender: TestPeer, at sentAt: Int64, mime: String?, in thread: String) -> AttachmentRow {
        AttachmentRow(id: id, senderId: sender.nodeId, sentAt: sentAt, isDM: false, conversationId: thread, mime: mime)
    }

    private func keys(_ ids: [String]) -> Set<ExactKey> {
        Set(ids.map(ExactKey.init))
    }

    // MARK: The rule

    @Test func theConstantsAreAFewPostsAndAbout256MiB() {
        #expect(StrangerRoomPhotos.perSender == 8 && StrangerRoomPhotos.overall == 32)
        #expect(Int64(StrangerRoomPhotos.overall) * Int64(8 * 1024 * 1024 + 64 * 1024) < 270 * 1024 * 1024)
    }

    @Test func aStrangerKeepsTheirNewestEight() {
        let stranger = TestPeer(seed: 9)
        let rows = (0..<12).map { row("p\($0)", from: stranger, at: Int64(1000 + $0)) }
        #expect(StrangerRoomPhotos.leftOut(rows.shuffled()) { _ in false } == keys(["p0", "p1", "p2", "p3"]))
    }

    @Test func strangersKeepTheNewest32AfterEachSendersEight() {
        let strangers = (0..<5).map { TestPeer(seed: 10 + $0) }
        // Five strangers posting eight each, interleaved in time: the oldest eight overall go.
        let rows = (0..<40).map { index in row("p\(index)", from: strangers[index % 5], at: Int64(1000 + index)) }
        #expect(StrangerRoomPhotos.leftOut(rows) { _ in false } == keys((0..<8).map { "p\($0)" }))

        // One stranger's flood takes its eight, and leaves the rest of the 32 to the others.
        let flood = (0..<40).map { row("f\($0)", from: strangers[0], at: Int64(5000 + $0)) }
        let older = (0..<8).map { row("o\($0)", from: strangers[1], at: Int64(1000 + $0)) }
        #expect(StrangerRoomPhotos.leftOut(flood + older) { _ in false } == keys((0..<32).map { "f\($0)" }))
    }

    @Test func knownSendersAreExemptAndTakeNoSlot() {
        let friend = TestPeer(seed: 20)
        let stranger = TestPeer(seed: 21)
        let theirs = (0..<50).map { row("k\($0)", from: friend, at: Int64(9000 + $0), mime: "audio/aac") }
        let strangers = (0..<8).map { row("s\($0)", from: stranger, at: Int64(1000 + $0)) }
        #expect(StrangerRoomPhotos.leftOut(theirs + strangers) { $0 == friend.nodeId }.isEmpty)
    }

    @Test func aTypeTheRoomRefusesIsLeftOutAndCountsForNothing() {
        let stranger = TestPeer(seed: 9)
        var rows = (0..<8).map { row("p\($0)", from: stranger, at: Int64(1000 + $0)) }
        rows.append(row("voice", from: stranger, at: 9999, mime: "audio/aac"))
        rows.append(row("bare", from: stranger, at: 500, mime: nil))
        #expect(
            StrangerRoomPhotos.leftOut(rows) { _ in false } == keys(["voice", "bare"]), "no type is a picture, and the oldest")
    }

    @Test func otherThreadsRowsAreNeverLeftOut() {
        let stranger = TestPeer(seed: 9)
        let rows = (0..<20).map { row("d\($0)", from: stranger, at: Int64($0), mime: "audio/aac", in: stranger.nodeId.string) }
        #expect(StrangerRoomPhotos.leftOut(rows) { _ in false }.isEmpty)
    }

    @Test func aTieIsBrokenByTheIdsBytesLargerFirst() {
        let stranger = TestPeer(seed: 9)
        // Equal as Swift strings, and two ids by their bytes: U+00E9 is C3 A9, after "e" and U+0301's 65 CC 81.
        let composed = row("\u{e9}", from: stranger, at: 7)
        let decomposed = row("e\u{301}", from: stranger, at: 7)
        #expect(StrangerRoomPhotos.isNewer(composed, than: decomposed) && !StrangerRoomPhotos.isNewer(decomposed, than: composed))
        #expect(StrangerRoomPhotos.isNewer(row("a", from: stranger, at: 8), than: composed), "sentAt first")
        let rows = [decomposed, composed] + (0..<7).map { row("z\($0)", from: stranger, at: 9) }
        #expect(StrangerRoomPhotos.leftOut(rows) { _ in false } == [ExactKey("e\u{301}")])
    }

    // MARK: In the engine

    private func post(by author: TestPeer, _ index: Int, at sentAt: Int64) throws -> (frame: TestFrame, bytes: [UInt8]) {
        let bytes = Array("photo \(index) by \(author.nodeId)".utf8)
        let content = ChatContent(body: "", attachmentHash: BlobHash(of: bytes).string, attachmentMime: "image/jpeg")
        return (try author.roomPost("", id: frameIdOf("post-\(index)"), sentAt: sentAt, content: content), bytes)
    }

    @Test func aStrangersTwelvePhotosAreWantedOnlyTheNewestEightAfterARestart() throws {
        let fixture = EngineFixture(alice)
        let stranger = TestPeer(seed: 9)
        try fixture.pin(stranger)
        let posts = try (0..<12).map { try post(by: stranger, $0, at: EngineFixture.start - 12_000 + Int64($0) * 1000) }
        // Newest first, so each lands outside the bound as soon as eight newer are in.
        for posted in posts.reversed() {
            fixture.deliver(posted.frame, from: stranger)
        }
        let wanted = Set(fixture.engine.blobExchange.wanted)
        #expect(wanted == Set(posts[4...].map { BlobHash(of: $0.bytes) }))
        #expect(fixture.log.all.contains { $0.hasSuffix("not fetched (past the room's bound)") })
        let restarted = EngineFixture(alice, stores: fixture.stores)
        #expect(Set(restarted.engine.blobExchange.wanted) == wanted)
    }

    /// Five strangers posting eight each, delivered oldest first as live posts come, each pin made first.
    private func fiveStrangersPosting(to fixture: EngineFixture, landing: Bool) throws -> [BlobHash] {
        let strangers = (0..<5).map { TestPeer(seed: 10 + $0) }
        for stranger in strangers {
            try fixture.pin(stranger)
        }
        var hashes: [BlobHash] = []
        for index in 0..<40 {
            let author = strangers[index % 5]
            let posted = try post(by: author, index, at: EngineFixture.start - 40_000 + Int64(index) * 1000)
            fixture.deliver(posted.frame, from: author)
            let hash = BlobHash(of: posted.bytes)
            hashes.append(hash)
            if landing {
                fixture.engine.receiveFile(
                    InboundFile(from: author.nodeId, kind: .attachment, hash: hash, mime: "image/jpeg", bytes: posted.bytes))
            }
        }
        return hashes
    }

    @Test func fortyStrangersPhotosPostedOldestFirstLeaveOnlyTheNewest32Wanted() throws {
        let fixture = EngineFixture(alice)
        let hashes = try fiveStrangersPosting(to: fixture, landing: false)
        #expect(Set(fixture.engine.blobExchange.wanted) == Set(hashes[8...]), "each newer post withdrew the one it pushed out")
        #expect(fixture.log.all.contains("debug mesh blob \(LinkManager.shown(hashes[0].string)) want withdrawn (past the room's bound)"))
        let first = TestPeer(seed: 10)
        let bytes = Array("photo 0 by \(first.nodeId)".utf8)
        fixture.engine.receiveFile(InboundFile(from: first.nodeId, kind: .attachment, hash: hashes[0], mime: "image/jpeg", bytes: bytes))
        #expect(!fixture.stores.blobs.contains(hashes[0]), "a file for a withdrawn want was not asked for")
        fixture.advance(60_000)
        #expect(Set(fixture.engine.blobExchange.wanted) == Set(hashes[8...]), "and the re-offer wants none of them back")
    }

    @Test func photosHeldThenPushedOutAreSweptAndNeverWantedAgain() throws {
        let fixture = EngineFixture(alice)
        let hashes = try fiveStrangersPosting(to: fixture, landing: true)
        #expect(hashes.allSatisfy(fixture.stores.blobs.contains), "each landed while it was inside the bound")
        let named = fixture.engine.referencedBlobs()
        #expect(named.isSuperset(of: hashes[8...]) && named.isDisjoint(with: hashes[..<8]), "carried frames name only what the bound keeps")

        fixture.advance(thirtyOneMinutes)
        #expect(hashes[8...].allSatisfy(fixture.stores.blobs.contains))
        #expect(!hashes[..<8].contains(where: fixture.stores.blobs.contains), "swept past an echo's life")
        fixture.advance(60_000)
        #expect(!hashes[..<8].contains(where: fixture.engine.blobExchange.isWanted), "and never wanted again")
        let restarted = EngineFixture(alice, stores: fixture.stores)
        #expect(restarted.engine.blobExchange.wanted.isEmpty)
    }

    @Test func aStrangersNinthPhotoCancelsTheAskForTheirOldest() throws {
        let fixture = EngineFixture(alice)
        let stranger = TestPeer(seed: 9)
        try fixture.pin(stranger)
        fixture.link(stranger, capabilities: Capabilities.local.union(.blobHave))
        let posts = try (0..<9).map { try post(by: stranger, $0, at: EngineFixture.start - 9000 + Int64($0) * 1000) }
        for posted in posts.prefix(8) {
            fixture.deliver(posted.frame, from: stranger)
        }
        let oldest = BlobHash(of: posts[0].bytes)
        #expect(fixture.transport.written(.blobRequest).map(\.to).contains(stranger.nodeId), "asked of its author")
        #expect(fixture.transport.written(.blobCancel).isEmpty)
        fixture.deliver(posts[8].frame, from: stranger)
        #expect(!fixture.engine.blobExchange.isWanted(oldest))
        let cancels = try fixture.transport.written(.blobCancel).map { ($0.to, try BlobCancelContent(decoding: $0.envelope.payload).hash) }
        #expect(cancels.count == 1 && cancels.first?.0 == stranger.nodeId && cancels.first?.1 == oldest.string)
        #expect(fixture.engine.blobExchange.wanted.count == 8)
    }

    @Test func aPushedOutPhotoStreamingInIsLeftToLandAndWithdrawnAtTheReOfferOnceItStops() throws {
        let fixture = EngineFixture(alice)
        let stranger = TestPeer(seed: 9)
        try fixture.pin(stranger)
        let posts = try (0..<9).map { try post(by: stranger, $0, at: EngineFixture.start - 9000 + Int64($0) * 1000) }
        for posted in posts.prefix(8) {
            fixture.deliver(posted.frame, from: stranger)
        }
        let oldest = BlobHash(of: posts[0].bytes)
        fixture.transport.arrivingFileKeys = [oldest]
        fixture.deliver(posts[8].frame, from: stranger)
        #expect(fixture.engine.blobExchange.isWanted(oldest), "its bytes are on the link already")
        fixture.transport.arrivingFileKeys = []
        fixture.advance(60_000)
        #expect(!fixture.engine.blobExchange.isWanted(oldest), "the re-offer withdraws it once nothing is arriving")
    }

    @Test func aPushedOutPhotoThatIsAPeersAdvertisedPhotoStaysWanted() throws {
        let fixture = EngineFixture(alice)
        let stranger = TestPeer(seed: 9)
        try fixture.pin(stranger)
        let posts = try (0..<9).map { try post(by: stranger, $0, at: EngineFixture.start - 9000 + Int64($0) * 1000) }
        for posted in posts.prefix(8) {
            fixture.deliver(posted.frame, from: stranger)
        }
        let oldest = BlobHash(of: posts[0].bytes)
        var record = try #require(fixture.stores.peers.peer(stranger.nodeId))
        record.advertisedAvatarHash = oldest
        fixture.stores.peers.upsert(record)
        fixture.deliver(posts[8].frame, from: stranger)
        #expect(fixture.engine.blobExchange.isWanted(oldest), "wanted as a photo, which the bound does not judge")
    }

    @Test(arguments: StoreKind.allCases)
    func aReOfferWhoseAcceptanceReadFailsWithdrawsNoContactsRoomPhoto(kind: StoreKind) throws {
        let directory = scratchDirectory("bound-unread")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, conversations) = try kind.storesRefusingConversationReads(blobs: directory, failures: ReportedFailures().record)
        let fixture = EngineFixture(alice, stores: stores)
        let friend = TestPeer(seed: 9)
        try fixture.pin(friend)
        fixture.link(friend, capabilities: Capabilities.local.union(.blobHave))
        fixture.befriend(friend)
        let posts = try (0..<9).map { try post(by: friend, $0, at: EngineFixture.start - 9000 + Int64($0) * 1000) }
        for posted in posts {
            fixture.deliver(posted.frame, from: friend)
        }
        let hashes = posts.map { BlobHash(of: $0.bytes) }
        #expect(hashes.allSatisfy(fixture.engine.blobExchange.isWanted), "a contact's room photos are exempt")
        conversations.failsReads = true
        fixture.advance(60_000)
        conversations.failsReads = false
        #expect(hashes.allSatisfy(fixture.engine.blobExchange.isWanted), "a failed read is not nobody known")
        #expect(fixture.transport.written(.blobCancel).isEmpty)
    }
}
