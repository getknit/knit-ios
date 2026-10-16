import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// This port's rules for ``AckSync``'s owed entries beyond knit-next's `AckSyncTest`: another author's link sends nothing,
/// a re-served post is owed once, a link sends oldest first, every entry point that sends sweeps, the cap evicts the oldest stamp,
/// a linked author's tick included, and ids compare by their bytes (ADR 2026-09.jc2x).
@Suite struct AckSyncOwedTests {
    private let me = fixtureNodeId(1)
    private let author = fixtureNodeId(2)
    private let other = fixtureNodeId(3)

    private func cleartext(_ ids: String...) -> [AckSync.Tick] {
        ids.map { AckSync.Tick(author: author, form: .cleartext(ackId: $0)) }
    }

    @Test func anotherAuthorsLinkSendsNothing() {
        var ledger = AckSync()
        let seals = LedgerSeals()
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [other], now: 0, seals: seals)
        #expect(ledger.linked(to: other, now: 10, seals: seals).isEmpty)
        #expect(ledger.retryPending(linked: [other], now: 20, seals: seals).isEmpty)
        #expect(ledger.count == 1)
    }

    @Test func aReServedPostStaysOwedOnce() {
        var ledger = AckSync()
        let seals = LedgerSeals()
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 5, seals: seals)
        #expect(ledger.count == 1)
        #expect(ledger.owe("m1", author: author, escalatable: false, me: me, linked: [author], now: 9, seals: seals) == cleartext("m1"))
        #expect(ledger.isEmpty)
    }

    @Test func aLinkSendsWhatItIsOwedOldestFirst() {
        var ledger = AckSync()
        let seals = LedgerSeals()
        for (index, id) in ["m1", "m2", "m3"].enumerated() {
            _ = ledger.owe(id, author: author, escalatable: false, me: me, linked: [], now: Int64(index), seals: seals)
        }
        #expect(ledger.linked(to: author, now: 10, seals: seals) == cleartext("m1", "m2", "m3"))
        #expect(ledger.linked(to: author, now: 20, seals: seals).isEmpty, "a tick sent over a live link is done")
    }

    @Test func anAgedOutTickIsDroppedNotSentAtLinkUp() {
        // Kotlin's link-up does not sweep, and its heal does; here every entry point that sends does, as the old ledger's
        // two did, so no tick past its day goes.
        var ledger = AckSync(owedMilliseconds: 100)
        let seals = LedgerSeals()
        _ = ledger.owe("old", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("new", author: author, escalatable: false, me: me, linked: [], now: 50, seals: seals)
        #expect(ledger.linked(to: author, now: 101, seals: seals) == cleartext("new"))
    }

    @Test func theLedgerEvictsItsOldestPastTheCap() {
        var ledger = AckSync(capacity: 2)
        let seals = LedgerSeals()
        for (index, id) in ["m1", "m2", "m3"].enumerated() {
            _ = ledger.owe(id, author: author, escalatable: false, me: me, linked: [], now: Int64(index), seals: seals)
        }
        #expect(ledger.linked(to: author, now: 10, seals: seals) == cleartext("m2", "m3"))
    }

    @Test func theSweepAgesTicksOut() {
        var ledger = AckSync(owedMilliseconds: 100)
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: LedgerSeals())
        ledger.sweep(now: 100)
        #expect(ledger.count == 1, "kept for the whole window")
        ledger.sweep(now: 101)
        #expect(ledger.isEmpty)
    }

    @Test func aLinkedAuthorsTickAtTheCapEvictsTheOldestOwedOne() {
        // Kotlin's rule (`AckSync.kt:184-188`): a fresh entry makes room first, a linked author's too, though it ends at
        // once. The ledger before P5c sent a linked author's tick and kept nothing, so this is the one change on the air
        // with the shipped seams: at the cap, the oldest absent author's tick is lost.
        var ledger = AckSync(capacity: 2)
        let seals = LedgerSeals()
        _ = ledger.owe("m1", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("m2", author: author, escalatable: false, me: me, linked: [], now: 1, seals: seals)
        let linked = ledger.owe("o1", author: other, escalatable: false, me: me, linked: [other], now: 2, seals: seals)
        #expect(linked == [AckSync.Tick(author: other, form: .cleartext(ackId: "o1"))], "sent at once")
        #expect(ledger.count == 1)
        #expect(ledger.linked(to: author, now: 3, seals: seals) == cleartext("m2"), "m1 made room for it")
    }

    @Test func idsThatSwiftCallsEqualAreOwedApart() {
        // "K" and the Kelvin sign are one string to Swift and two frames to Android (ADR 2026-09.jc2x).
        var ledger = AckSync()
        let seals = LedgerSeals()
        _ = ledger.owe("tick-K", author: author, escalatable: false, me: me, linked: [], now: 0, seals: seals)
        _ = ledger.owe("tick-\u{212A}", author: author, escalatable: false, me: me, linked: [], now: 1, seals: seals)
        #expect(ledger.count == 2)
        let ids = ledger.linked(to: author, now: 2, seals: seals).cleartextIds
        #expect(Set(ids.map { Array($0.utf8) }).count == 2, "two ticks, one per frame")
    }
}
