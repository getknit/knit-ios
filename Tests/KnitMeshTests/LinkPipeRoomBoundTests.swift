import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Both sides of the bound on strangers' room photos over a link pipe (knit-ios #21): a stranger's engine posts twelve
/// photos in the room in one burst, oldest first, and the iPhone's side wants at most eight of them at any time, takes
/// eight copies, and withdraws each want the bound pushes out.
@Suite struct LinkPipeRoomBoundTests {
    @Test func aStrangersTwelvePhotosCostAtMostEightWantsAndEightCopies() throws {
        let lab = PipeLab()
        let alice = lab.node(1)
        let stranger = lab.node(2)
        let pipe = lab.link(alice, stranger)
        #expect(lab.run { alice.stores.peers.peer(stranger.nodeId) != nil })
        // The twelve come in one burst, as a flood or a back-fill does: the stranger's radio holds them until all are sent.
        pipe.holding = stranger
        var hashes: [BlobHash] = []
        for index in 0..<12 {
            lab.clock.advance(1000)
            let picture: [UInt8] = (0..<60_000).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761 &+ index &* 7919) >> 9) }
            let posted = try #require(stranger.engine.postToRoom("", photo: OutgoingPhoto(bytes: picture, mime: "image/jpeg")))
            hashes.append(try #require(posted.attachment?.hash))
        }
        pipe.holding = nil
        let theirs = Set(hashes)
        var mostWanted = 0
        lab.run(limit: 120_000) {
            mostWanted = max(mostWanted, alice.engine.blobExchange.wanted.count { theirs.contains($0) })
            return false
        }
        let copies = pipe.serves.count { theirs.contains($0.hash) }
        let withdrawn = alice.log.all.count { $0.hasSuffix("want withdrawn (past the room's bound)") }
        #expect(mostWanted <= 8, "wanted at most eight at once: \(mostWanted)")
        #expect(copies == 8, "eight copies crossed, one each: \(copies)")
        #expect(Set(hashes.filter(alice.stores.blobs.contains)) == Set(hashes.suffix(8)), "the newest eight are held")
        #expect(withdrawn == 4, "each post past the eighth withdrew the oldest want: \(withdrawn)")
        // Withdrawn before any ask stood, since the burst landed ahead of the queries' answers, so there was nobody to
        // cancel; a standing ask's cancel is `StrangerRoomPhotosTests.aStrangersNinthPhotoCancelsTheAskForTheirOldest`.
        #expect(alice.engine.blobCounts.cancelsSent == 0)
    }
}
