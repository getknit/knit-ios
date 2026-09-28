import KnitMesh
import Testing

/// At most one digest waits on a link, and a newer one takes its place (knit-next ADR 2026-09.tjfb and
/// `FramedLinkTest.kt`'s four digest tests).
@Suite struct LinkOutboxTests {
    private let backfill = [UInt8](repeating: 7, count: 1000)
    private let live: [UInt8] = [1, 2, 3]

    /// Writes everything, `limit` bytes at a time, and answers each piece in order.
    private func drain(_ outbox: inout LinkOutbox, limit: Int = 1 << 20) -> [[UInt8]] {
        var pieces: [[UInt8]] = []
        while let next = outbox.next(atMost: limit) {
            pieces.append(Array(next))
            outbox.wrote(next.count)
        }
        return pieces
    }

    @Test func digestsOfferedWhileTheWriterIsBusyCollapseIntoTheNewest() {
        // On hci1 a back-fill held one digest per 60 s tick, each minutes stale when written and each ahead of every
        // frame queued after it.
        var outbox = LinkOutbox()
        outbox.append(backfill)
        let replaced = [outbox.offerDigest([0xD1]), outbox.offerDigest([0xD2, 0xD2]), outbox.offerDigest([0xD3, 0xD3, 0xD3])]
        #expect(replaced == [false, true, true])
        outbox.append(live)
        #expect(drain(&outbox) == [backfill, [0xD3, 0xD3, 0xD3], live], "one digest, the newest, then the live frame")
        #expect(outbox.isEmpty)
    }

    @Test func anIdleLinkWritesEveryDigestItIsHanded() {
        var outbox = LinkOutbox()
        let first = outbox.offerDigest([0xD1])
        #expect(!first)
        #expect(drain(&outbox) == [[0xD1]])
        let second = outbox.offerDigest([0xD2])
        #expect(!second, "the slot emptied when the first was written")
        #expect(drain(&outbox) == [[0xD2]])
    }

    @Test func aDigestPartlyWrittenIsNeverRewrittenAndTheNextQueuesBehindIt() throws {
        var outbox = LinkOutbox()
        outbox.offerDigest([0xA1, 0xA2, 0xA3, 0xA4])
        let first = try #require(outbox.next(atMost: 2))
        outbox.wrote(first.count)
        let replaced = outbox.offerDigest([0xB1])
        #expect(!replaced, "the first is already going out, so the newer one is a record of its own")
        #expect(drain(&outbox, limit: 2) == [[0xA3, 0xA4], [0xB1]])
    }

    @Test func aDigestWaitingForSpaceCanStillBeReplaced() {
        // The writer reaching the digest is not enough: until a byte of it is written, a newer one takes its place.
        var outbox = LinkOutbox()
        outbox.offerDigest([0xA1])
        #expect(outbox.next(atMost: 8) == [0xA1])
        outbox.wrote(0)
        let replaced = outbox.offerDigest([0xB1, 0xB2])
        #expect(replaced)
        #expect(drain(&outbox) == [[0xB1, 0xB2]])
    }

    @Test func aDigestStillRidesAheadOfWhatWasQueuedAfterIt() {
        var outbox = LinkOutbox()
        outbox.append(backfill)
        outbox.offerDigest([0xD1])
        outbox.append(live)
        outbox.offerDigest([0xD2])
        #expect(drain(&outbox) == [backfill, [0xD2], live], "the newer digest keeps the older one's place")
    }

    @Test func writesAreCutToTheLimitWithinOneEntry() {
        var outbox = LinkOutbox()
        outbox.append([1, 2, 3, 4, 5])
        outbox.offerDigest([6, 7, 8])
        #expect(drain(&outbox, limit: 2) == [[1, 2], [3, 4], [5], [6, 7], [8]])
    }

    @Test func queuedBytesCountsTheWaitingDigestAtItsNewestSize() throws {
        var outbox = LinkOutbox()
        outbox.append(live)
        outbox.offerDigest([UInt8](repeating: 0, count: 10))
        #expect(outbox.queuedBytes == 13)
        outbox.offerDigest([UInt8](repeating: 0, count: 4))
        #expect(outbox.queuedBytes == 7)
        let next = try #require(outbox.next(atMost: 2))
        outbox.wrote(next.count)
        #expect(outbox.queuedBytes == 5)
        outbox.removeAll()
        #expect(outbox.queuedBytes == 0)
        #expect(outbox.isEmpty)
        #expect(outbox.next(atMost: 8) == nil)
    }

    @Test func emptyWritesQueueNothing() {
        var outbox = LinkOutbox()
        outbox.append([])
        let replaced = outbox.offerDigest([])
        #expect(!replaced)
        #expect(outbox.isEmpty)
    }
}
