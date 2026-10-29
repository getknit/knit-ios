import Testing

@testable import KnitMesh

/// The era, floor, bound and age of the sealed DM re-ack memo (knit-next #176, ADR 2026-10.8hn6): knit-next's
/// `DmReAckLedgerTest` (at `afdd37204`), case by case under its Kotlin names. Pure: the clock is a parameter. The custody
/// half of the rule, and who records, are ``MeshEngineReAckTests``'.
@Suite struct DmReAckLedgerTests {
    private static let start: Int64 = 1_000_000_000
    private static let minute: Int64 = 60_000
    private static let hour: Int64 = 60 * minute

    private var floor: Int64 { DmReAckLedger.floorMilliseconds }

    @Test func aReceiptAnswersARedeliveryUnderItsOwnRootInsideTheFloor() {
        var ledger = DmReAckLedger()
        ledger.record(acked: "dm", rootTag: 7, receiptId: "r1", now: Self.start)

        #expect(ledger.heldReceipt(acked: "dm", currentRootTag: 7, now: Self.start + floor - 1) == "r1")
        #expect(ledger.heldReceipt(acked: "dm", currentRootTag: 7, now: Self.start + floor) == nil, "past the floor")
        #expect(ledger.entry("dm") != nil, "past the floor is not past the TTL: the entry stays for its step")
    }

    @Test func anotherRootOrNoSessionReSeals() {
        var ledger = DmReAckLedger()
        ledger.record(acked: "dm", rootTag: 7, receiptId: "r1", now: Self.start)

        #expect(ledger.heldReceipt(acked: "dm", currentRootTag: 8, now: Self.start + 1) == nil, "a reset moved the root")
        #expect(ledger.heldReceipt(acked: "dm", currentRootTag: nil, now: Self.start + 1) == nil, "no session held now")
        #expect(ledger.heldReceipt(acked: "other", currentRootTag: 7, now: Self.start + 1) == nil, "never acked")
    }

    @Test func theFloorDoublesPerSameEraReSealUpToFourHours() {
        #expect(DmReAckLedger.floor(step: 0) == 15 * Self.minute)
        #expect(DmReAckLedger.floor(step: 1) == 30 * Self.minute)
        #expect(DmReAckLedger.floor(step: 4) == 4 * Self.hour)
        #expect(DmReAckLedger.floor(step: 40) == 4 * Self.hour)
        #expect(DmReAckLedger.floor(step: -1) == 15 * Self.minute, "a step below zero reads as the first")

        var ledger = DmReAckLedger()
        var now = Self.start
        ledger.record(acked: "dm", rootTag: 7, receiptId: "r0", now: now)
        for step in 0..<6 {
            now += DmReAckLedger.floor(step: step)
            ledger.record(acked: "dm", rootTag: 7, receiptId: "r\(step + 1)", now: now)
        }
        #expect(ledger.entry("dm")?.step == 4)
        #expect(ledger.heldReceipt(acked: "dm", currentRootTag: 7, now: now + DmReAckLedger.maxFloorMilliseconds - 1) == "r6")
    }

    @Test func aNewEraStartsItsOwnFloor() {
        var ledger = DmReAckLedger()
        ledger.record(acked: "dm", rootTag: 7, receiptId: "r0", now: Self.start)
        ledger.record(acked: "dm", rootTag: 7, receiptId: "r1", now: Self.start + floor)
        #expect(ledger.entry("dm")?.step == 1)

        ledger.record(acked: "dm", rootTag: 8, receiptId: "r2", now: Self.start + floor + 1)
        #expect(ledger.entry("dm")?.step == 0)
        #expect(ledger.entry("dm")?.rootTag == 8)
    }

    @Test func anEntryAgesOutATtlAfterItsLastReceipt() {
        var ledger = DmReAckLedger(capacity: 1000, ttlMilliseconds: Self.hour)
        ledger.record(acked: "dm", rootTag: 7, receiptId: "r1", now: Self.start)

        #expect(ledger.heldReceipt(acked: "dm", currentRootTag: 7, now: Self.start + Self.hour) == nil)
        #expect(ledger.entry("dm") == nil, "and is dropped")
    }

    /// Custody's own bounds unless told otherwise, so the memo never outlives the receipt it names.
    @Test func itsBoundsAreCustodys() {
        let ledger = DmReAckLedger()
        #expect(ledger.capacity == 1000 && ledger.ttlMilliseconds == 24 * Self.hour)
    }

    /// Our clock stepped back past the receipt's stamp: read as past the floor, so the re-arm is not held back by the jump.
    @Test func aClockSteppedBackBeforeTheReceiptReSeals() {
        var ledger = DmReAckLedger()
        ledger.record(acked: "dm", rootTag: 7, receiptId: "r1", now: Self.start)

        #expect(ledger.heldReceipt(acked: "dm", currentRootTag: 7, now: Self.start - 1) == nil)
        #expect(ledger.entry("dm") == nil, "and the entry is dropped")
    }

    @Test func theBoundEvictsTheOldestReceiptFirst() {
        var ledger = DmReAckLedger(capacity: 3, ttlMilliseconds: 24 * Self.hour)
        ledger.record(acked: "a", rootTag: 7, receiptId: "ra", now: Self.start)
        ledger.record(acked: "b", rootTag: 7, receiptId: "rb", now: Self.start + 1)
        ledger.record(acked: "c", rootTag: 7, receiptId: "rc", now: Self.start + 2)
        // A re-seal of the oldest moves it to the newest end.
        ledger.record(acked: "a", rootTag: 7, receiptId: "ra2", now: Self.start + 3)
        ledger.record(acked: "d", rootTag: 7, receiptId: "rd", now: Self.start + 4)

        #expect(ledger.count == 3)
        #expect(ledger.entry("b") == nil, "b was the oldest receipt")
        #expect(ledger.entry("a")?.receiptId == "ra2")
        #expect(ledger.heldReceipt(acked: "d", currentRootTag: 7, now: Self.start + 5) == "rd")
    }

    /// Ids compare by their bytes (ADR 2026-09.jc2x): two canonically equivalent spellings are two DMs, as on Android.
    @Test func idsCompareByTheirBytes() {
        var ledger = DmReAckLedger()
        ledger.record(acked: "caf\u{E9}", rootTag: 7, receiptId: "r1", now: Self.start)
        #expect("caf\u{E9}" == "cafe\u{301}", "Swift's String equality is canonical equivalence")
        #expect(ledger.heldReceipt(acked: "cafe\u{301}", currentRootTag: 7, now: Self.start + 1) == nil)
        #expect(ledger.heldReceipt(acked: "caf\u{E9}", currentRootTag: 7, now: Self.start + 1) == "r1")
    }
}
