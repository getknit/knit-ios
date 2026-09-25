import KnitMesh
import KnitTestSupport
import Testing

/// Room ticks owed to authors, ported from knit-next's `AckSyncTest` (its cleartext cases).
@Suite struct AckSyncTests {
    private let me = fixtureNodeId(1)
    private let author = fixtureNodeId(2)
    private let other = fixtureNodeId(3)

    @Test func aLinkedAuthorIsTickedAtOnceAndNothingIsOwed() {
        var ledger = AckSync()
        let now = ledger.owe("m1", author: author, me: me, authorLinked: true, now: 0)
        #expect(now)
        #expect(ledger.isEmpty)
    }

    @Test func anAbsentAuthorsTickWaitsForItsLink() {
        var ledger = AckSync()
        let now = ledger.owe("m1", author: author, me: me, authorLinked: false, now: 0)
        let elsewhere = ledger.linked(to: other, now: 10)
        let home = ledger.linked(to: author, now: 20)
        let again = ledger.linked(to: author, now: 30)
        #expect(!now)
        #expect(elsewhere.isEmpty)
        #expect(home == ["m1"])
        #expect(again.isEmpty, "a tick sent over a live link is done")
    }

    @Test func ourOwnPostsAreNeverTicked() {
        var ledger = AckSync()
        let now = ledger.owe("m1", author: me, me: me, authorLinked: true, now: 0)
        #expect(!now)
        #expect(ledger.isEmpty)
    }

    @Test func aReServedPostStaysOwedOnce() {
        var ledger = AckSync()
        _ = ledger.owe("m1", author: author, me: me, authorLinked: false, now: 0)
        _ = ledger.owe("m1", author: author, me: me, authorLinked: false, now: 5)
        #expect(ledger.count == 1)
        let linkedNow = ledger.owe("m1", author: author, me: me, authorLinked: true, now: 9)
        #expect(linkedNow)
        #expect(ledger.isEmpty)
    }

    @Test func ticksGoHomeOldestFirst() {
        var ledger = AckSync()
        for (index, id) in ["m1", "m2", "m3"].enumerated() {
            _ = ledger.owe(id, author: author, me: me, authorLinked: false, now: Int64(index))
        }
        let due = ledger.linked(to: author, now: 10)
        #expect(due == ["m1", "m2", "m3"])
    }

    @Test func anAgedOutTickIsDroppedNotSent() {
        var ledger = AckSync(owedMilliseconds: 100)
        _ = ledger.owe("old", author: author, me: me, authorLinked: false, now: 0)
        _ = ledger.owe("new", author: author, me: me, authorLinked: false, now: 50)
        let due = ledger.linked(to: author, now: 101)
        #expect(due == ["new"])
    }

    @Test func theLedgerEvictsItsOldestPastTheCap() {
        var ledger = AckSync(capacity: 2)
        for (index, id) in ["m1", "m2", "m3"].enumerated() {
            _ = ledger.owe(id, author: author, me: me, authorLinked: false, now: Int64(index))
        }
        let due = ledger.linked(to: author, now: 10)
        #expect(due == ["m2", "m3"])
    }

    @Test func theSweepAgesTicksOut() {
        var ledger = AckSync(owedMilliseconds: 100)
        _ = ledger.owe("m1", author: author, me: me, authorLinked: false, now: 0)
        ledger.sweep(now: 100)
        #expect(ledger.count == 1, "kept for the whole window")
        ledger.sweep(now: 101)
        #expect(ledger.isEmpty)
    }
}
