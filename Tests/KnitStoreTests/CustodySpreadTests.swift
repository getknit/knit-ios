import KnitStore
import KnitWire
import Testing

/// A DM to `peer` from `sender`, unsigned as the store tests' frames are.
private func dm(_ id: String, sender: String, sentAt: Int64) -> CarriedFrame {
    let envelope = RelayEnvelope(
        type: .chat, id: id, senderId: sender, sentAt: sentAt, recipientId: "peer", payload: ChatContent(body: "").encoded)
    return CarriedFrame(envelope: envelope, sig: [], signed: envelope.encoded)
}

/// A carry that answers from a fixed table and records every id it is asked about.
private final class SpyCarry: CustodyCarry {
    var table: [String: Int]
    private(set) var asked: [String] = []

    init(_ table: [String: Int] = [:]) {
        self.table = table
    }

    func holders(of id: String) -> Int {
        asked.append(id)
        return table[id] ?? 0
    }
}

/// The global cap's key 2, spread (the `custody-carry-policy` contract, §5), run against every store: count DESC, spread
/// DESC, sentAt ASC, id ASC bytewise, only the global cap reading the carry, and only while it binds.
@Suite struct CustodySpreadTests {
    private static let kinds = CustodyStoreKind.allCases

    /// `ids` from `sender`, `sentAt` 10, 11, … in order.
    private static func fill(_ store: any CustodyStore, _ ids: [String], sender: String, from sentAt: Int64 = 10) {
        for (index, id) in ids.enumerated() {
            store.store(dm(id, sender: sender, sentAt: sentAt + Int64(index)), origin: .relayed, now: 0)
        }
    }

    private static func live(_ store: any CustodyStore) -> Set<String> {
        Set(store.liveIds(now: 0))
    }

    @Test func theSpreadCapIsEight() {
        #expect(CustodyLimits().spreadMax == 8)
    }

    @Test(arguments: kinds)
    func inTheLargestBucketTheRowHeldByMoreGoesBeforeAnOlderOne(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxFrames: 3))
        Self.fill(store, ["a1", "a2", "a3"], sender: "A")
        let result = store.store(dm("a4", sender: "A", sentAt: 20), origin: .relayed, now: 0, carry: SpyCarry(["a2": 1]))
        #expect(result.held)
        #expect(result.evicted == ["a2"])
        #expect(Self.live(store) == ["a1", "a3", "a4"])
    }

    @Test(arguments: kinds)
    func holdersPastTheCapTieWithTheCapAndTheOldestGoes(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxFrames: 3, spreadMax: 3))
        Self.fill(store, ["a1", "a2", "a3"], sender: "A")
        let result = store.store(dm("a4", sender: "A", sentAt: 20), origin: .relayed, now: 0, carry: SpyCarry(["a2": 3, "a3": 9]))
        #expect(result.evicted == ["a2"], "nine ties with three, and a2 is older")
    }

    @Test(arguments: kinds)
    func theSendersCountStillComesFirst(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxFrames: 3))
        Self.fill(store, ["a1", "a2"], sender: "A")
        Self.fill(store, ["b1"], sender: "B", from: 1)
        let result = store.store(dm("b2", sender: "B", sentAt: 2), origin: .relayed, now: 0, carry: SpyCarry(["b1": 8, "b2": 8]))
        // A and B hold two each: spread picks among both, and B's full spread goes before A's none.
        #expect(result.evicted == ["b1"])
        let again = store.store(dm("c1", sender: "C", sentAt: 0), origin: .relayed, now: 0, carry: SpyCarry(["b2": 8]))
        // A holds two and B one: A's oldest goes though B's frame is held by eight and is older.
        #expect(again.evicted == ["a1"])
    }

    @Test(arguments: kinds)
    func aNewcomerHeldByAsManyAsTheRestIsEvictedByItsOwnWriteWhenOldest(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxFrames: 3))
        Self.fill(store, ["a1", "a2", "a3"], sender: "A", from: 10)
        let result = store.store(
            dm("a0", sender: "A", sentAt: 5), origin: .relayed, now: 0, carry: SpyCarry(["a0": 1, "a1": 1, "a2": 1, "a3": 1]))
        #expect(!result.held)
        #expect(result.changed)
        #expect(result.evicted == ["a0"])
        // Counted as held by none, the same newcomer outlives every shared row.
        let fresh = try kind.make(CustodyLimits(maxFrames: 3))
        Self.fill(fresh, ["a1", "a2", "a3"], sender: "A", from: 10)
        let alone = fresh.store(dm("a0", sender: "A", sentAt: 5), origin: .relayed, now: 0, carry: SpyCarry(["a1": 1, "a2": 1, "a3": 1]))
        #expect(alone.held)
        #expect(alone.evicted == ["a1"])
    }

    @Test(arguments: kinds)
    func aQuotaTrimNeverReadsTheCarry(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxPerSender: 3))
        Self.fill(store, ["a1", "a2", "a3"], sender: "A")
        let spy = SpyCarry(["a3": 8])
        let result = store.store(dm("a4", sender: "A", sentAt: 20), origin: .relayed, now: 0, carry: spy)
        #expect(result.evicted == ["a1"], "the oldest, though a newer row is held by eight")
        #expect(spy.asked.isEmpty)
    }

    @Test(arguments: kinds)
    func belowTheCapACarryChangesNothingAndIsNotRead(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxFrames: 10))
        Self.fill(store, ["a1", "a2", "a3"], sender: "A")
        let spy = SpyCarry(["a1": 8, "a2": 8])
        let result = store.store(dm("a4", sender: "A", sentAt: 20), origin: .relayed, now: 0, carry: spy)
        #expect(result.evicted.isEmpty)
        #expect(spy.asked.isEmpty)
        #expect(Self.live(store) == ["a1", "a2", "a3", "a4"])
    }

    @Test(arguments: kinds)
    func theCapReadsEachRowsSpreadOncePerWrite(kind: CustodyStoreKind) throws {
        let store = try kind.make(CustodyLimits(maxFrames: 4))
        Self.fill(store, ["a1", "a2"], sender: "A")
        Self.fill(store, ["b1", "b2"], sender: "B", from: 30)
        let spy = SpyCarry()
        let result = store.store(dm("c1", sender: "C", sentAt: 50), origin: .relayed, now: 0, carry: spy)
        #expect(result.evicted == ["a1"])
        #expect(spy.asked.sorted() == ["a1", "a2", "b1", "b2", "c1"], "each live row once, the newcomer included")
    }

    @Test(arguments: kinds)
    func withNoHolderTheOrderIsTodays(kind: CustodyStoreKind) throws {
        let limits = CustodyLimits(maxFrames: 7, maxPerSender: 4)
        let plain = try kind.make(limits)
        let carried = try kind.make(limits)
        var random = SplitMix(state: 41)
        for index in 0..<40 {
            let frame = dm(
                "f\(index)", sender: "s\(Int.random(in: 0..<4, using: &random))", sentAt: Int64.random(in: 0..<30, using: &random))
            let old = plain.store(frame, origin: .relayed, now: 0)
            let new = carried.store(frame, origin: .relayed, now: 0, carry: NoCustodyCarry())
            #expect(old == new)
        }
        #expect(Self.live(plain) == Self.live(carried))
    }

    @Test(arguments: kinds)
    func everyEvictionTakesOneRowOfALargestBucket(kind: CustodyStoreKind) throws {
        // Whichever row the later keys pick, one of the largest buckets loses exactly one row, so the bucket sizes a flood
        // can reach are what they were.
        let store = try kind.make(CustodyLimits(maxFrames: 20))
        var random = SplitMix(state: 7)
        var table: [String: Int] = [:]
        var senders: [String: String] = [:]
        for index in 0..<120 {
            let id = "f\(index)"
            let sender = "s\(Int.random(in: 0..<6, using: &random))"
            table[id] = Int.random(in: 0..<10, using: &random)
            senders[id] = sender
            var buckets = Self.buckets(store)
            buckets[sender, default: 0] += 1
            let largest = buckets.values.max() ?? 0
            let result = store.store(
                dm(id, sender: sender, sentAt: Int64.random(in: 0..<500, using: &random)), origin: .relayed, now: 0, carry: SpyCarry(table))
            #expect(result.evicted.count == (index < 20 ? 0 : 1))
            for victim in result.evicted {
                #expect(buckets[senders[victim] ?? ""] == largest, "\(victim) from a bucket of \(largest)")
            }
        }
    }

    @Test(arguments: kinds)
    func noTieDependsOnArrivalOrder(kind: CustodyStoreKind) throws {
        // The same live set, stored in three orders below the cap, then the same newcomer: the same victim each time.
        let frames = (0..<6).map { dm("x\($0)", sender: $0 < 3 ? "A" : "B", sentAt: 10) }
        let table = ["x0": 2, "x1": 2, "x2": 2, "x3": 2, "x4": 2, "x5": 2, "y": 2]
        var victims: [[String]] = []
        for order in [frames, frames.reversed(), [frames[3], frames[0], frames[5], frames[1], frames[4], frames[2]]] {
            let store = try kind.make(CustodyLimits(maxFrames: 6))
            for frame in order {
                store.store(frame, origin: .relayed, now: 0)
            }
            victims.append(store.store(dm("y", sender: "C", sentAt: 10), origin: .relayed, now: 0, carry: SpyCarry(table)).evicted)
        }
        #expect(victims == [["x0"], ["x0"], ["x0"]])
    }

    /// How many live rows each sender holds.
    private static func buckets(_ store: any CustodyStore) -> [String: Int] {
        store.liveIndex(now: 0).reduce(into: [:]) { $0[$1.senderId, default: 0] += 1 }
    }
}

/// SplitMix64, so each seeded run is the same every time.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
