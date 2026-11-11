import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// ``TagSchedule``, ported case for case from knit-next's `TagScheduleTest` at `cad69c77b` (ADR 2026-11.prsp): no (slot,
/// restart) is ever draws.aired twice under one key, whatever the wall clock does, across bring-ups and restarts; a random tag
/// carries the prefix and resolves to nobody. Every draw comes from a seeded generator.
@Suite struct TagScheduleTests {
    static let key = required(PresenceKey(bytes: (0..<32).map { UInt8($0) }))
    static let wall: Int64 = 1_800_000_000_000
    static let slot = BlindTag.slotOf(wallMilliseconds: wall)
    static let dayMilliseconds: Int64 = 24 * 3_600_000
    static let me = LinkRig.high

    let store = FakeMarks()
    let draws = Draws()

    /// The generator, and every tag draws.aired, so a repeat shows as a duplicate.
    final class Draws {
        var random = SeededGenerator(seed: 1)
        var aired: [NodeId] = []
    }

    static func own(_ generation: Int64 = 1, _ key: PresenceKey = key) -> OwnPresenceKey {
        OwnPresenceKey(generation: generation, key: key)
    }

    static func expected(_ key: PresenceKey = key, slot: Int64, restart: Int) -> NodeId {
        BlindFixture.tag(key, owner: me, slot: slot, restart: restart)
    }

    func schedule() -> TagSchedule {
        TagSchedule(owner: Self.me.bytes)
    }

    @discardableResult
    func air(_ schedule: inout TagSchedule, wall: Int64, generation: Int64 = 1, under key: PresenceKey = key) throws -> TagSchedule.Next {
        let next = try schedule.next(key: Self.own(generation, key), wall: wall, marks: store, using: &draws.random)
        draws.aired.append(next.tag)
        return next
    }

    func noRepeat() -> Bool {
        Set(draws.aired).count == draws.aired.count
    }

    @Test func aNewGenerationStartsAtTheCurrentSlot() throws {
        var schedule = schedule()
        let next = try air(&schedule, wall: Self.wall)
        #expect(next.resolvable)
        #expect(next.tag == Self.expected(slot: Self.slot, restart: 0))
        #expect(store.marks[1] == PresenceMark(slot: Self.slot, restart: 0))
        #expect(
            try air(&schedule, wall: Self.wall, generation: 2).tag == Self.expected(slot: Self.slot, restart: 0),
            "a newer generation has no mark")
    }

    @Test func fiveBringUpsInOneSlotNeverRepeat() throws {
        var schedule = schedule()
        var nexts: [TagSchedule.Next] = []
        for index in 0..<5 {
            nexts.append(try air(&schedule, wall: Self.wall + Int64(index) * 1000))
        }
        #expect(nexts.map(\.resolvable) == [true, true, true, true, false])
        for restart in 0..<BlindTag.restarts {
            #expect(nexts[restart].tag == Self.expected(slot: Self.slot, restart: restart))
        }
        #expect(noRepeat())
        #expect(try air(&schedule, wall: Self.wall + BlindTag.slotMilliseconds).resolvable, "the next slot resolves again")
    }

    @Test func aClockSteppingBackAndForthAcrossSlotEdgesNeverRepeats() throws {
        var schedule = schedule()
        let steps: [Int64] = [0, 1, 2, 1, 0, -3, 2, 2, 3, 1, 3, 4, 2, 5]
        var nexts: [TagSchedule.Next] = []
        for step in steps {
            nexts.append(try air(&schedule, wall: Self.wall + step * BlindTag.slotMilliseconds + 1))
        }
        #expect(noRepeat())
        #expect(!nexts[3].resolvable, "slot 1 after slot 2 was draws.aired")
        #expect(nexts[8].resolvable, "slot 3 is above every mark so far")
        #expect(nexts.last?.resolvable == true)
    }

    @Test func aProcessRestartOverTheSameStoreNeverRepeats() throws {
        for (seed, offset) in [(1, 0), (2, 0), (3, 60_000), (4, -BlindTag.slotMilliseconds), (5, 0), (6, 0)] as [(UInt64, Int64)] {
            var schedule = schedule()
            draws.random = SeededGenerator(seed: seed)
            try air(&schedule, wall: Self.wall + offset)
        }
        #expect(noRepeat())
        #expect(store.marks[1] == PresenceMark(slot: Self.slot, restart: 3))
    }

    @Test func aRandomFallbackCarriesThePrefixAndResolvesToNobody() throws {
        var schedule = schedule()
        for _ in 0..<BlindTag.restarts {
            try air(&schedule, wall: Self.wall)
        }
        let fallback = try air(&schedule, wall: Self.wall)
        #expect(!fallback.resolvable)
        #expect(AdvertForm.hasTagPrefix(fallback.tag.bytes))
        let table = ExpectedTagTable(previousKeyMaxMilliseconds: 1000)
        table.setKeys([Self.me: required(ExpectedTagTable.ContactKey(keys: [Self.key]))], now: 0, wall: Self.wall)
        #expect(table.lookup(fallback.tag, now: 0) == nil)
        #expect(table.lookup(draws.aired[0], now: 0)?.nodeId == Self.me)
        // A tag is the writer's: the same key listed under another id does not resolve it.
        let other = ExpectedTagTable(previousKeyMaxMilliseconds: 1000)
        other.setKeys([LinkRig.low: required(ExpectedTagTable.ContactKey(keys: [Self.key]))], now: 0, wall: Self.wall)
        #expect(other.lookup(draws.aired[0], now: 0) == nil)
        #expect(!"\(fallback)".contains(fallback.tag.string.dropFirst(4)), "the diagnostics name no tag")
    }

    @Test func aMarkLeftInTheFutureIsFlaggedStaleAndANewGenerationStartsNow() throws {
        for (index, pushed) in [Self.dayMilliseconds, 30 * Self.dayMilliseconds].enumerated() {
            let generation = 10 * Int64(index + 1)
            let old = required(PresenceKey(bytes: [UInt8](repeating: UInt8(index + 1), count: 32)))
            var schedule = schedule()
            draws.random = SeededGenerator(seed: 10 + UInt64(index))
            try air(&schedule, wall: Self.wall, generation: generation, under: old)
            #expect(try air(&schedule, wall: Self.wall + pushed, generation: generation, under: old).resolvable)
            let back = try air(&schedule, wall: Self.wall + 60_000, generation: generation, under: old)
            #expect(back.stale, "the clock came back: the mark is stale")
            #expect(!back.resolvable)
            #expect(AdvertForm.hasTagPrefix(back.tag.bytes))
            // The wiring asks for a new key generation: no mark, so it starts at the current slot.
            let fresh = required(PresenceKey(bytes: [UInt8](repeating: UInt8(index + 100), count: 32)))
            let next = try air(&schedule, wall: Self.wall + 60_000, generation: generation + 1, under: fresh)
            #expect(next.resolvable)
            #expect(!next.stale)
            #expect(next.tag == Self.expected(fresh, slot: Self.slot, restart: 0))
        }
        #expect(noRepeat())
        var schedule = schedule()
        try air(&schedule, wall: Self.wall, generation: 99)
        #expect(!(try air(&schedule, wall: Self.wall - BlindTag.slotMilliseconds, generation: 99).stale), "within the lead: not stale")
    }

    @Test func theStaleEdgeIsTheWindowsAheadEdge() throws {
        let lead = BlindTag.windowAheadSlots
        var schedule = schedule()
        try air(&schedule, wall: Self.wall + (lead + 1) * BlindTag.slotMilliseconds, generation: 1)
        #expect(!(try air(&schedule, wall: Self.wall + BlindTag.slotMilliseconds, generation: 1).stale), "exactly the lead ahead")
        try air(&schedule, wall: Self.wall + (lead + 1) * BlindTag.slotMilliseconds, generation: 2)
        #expect(try air(&schedule, wall: Self.wall, generation: 2).stale, "one past the lead")
    }

    @Test func theAnnouncedTagIsTheOneAiredAtTheRotation() throws {
        var schedule = schedule()
        try air(&schedule, wall: Self.wall)
        let announced = try schedule.reserve(key: Self.own(), wall: Self.wall, marks: store, using: &draws.random)
        #expect(announced.tag == Self.expected(slot: Self.slot + 1, restart: 0))
        let bringUp = try air(&schedule, wall: Self.wall + 1000)
        #expect(!bringUp.resolvable, "a bring-up inside the announcement's lead airs a random tag")
        let taken = schedule.take(1, wall: Self.wall + BlindTag.slotMilliseconds)
        let rotation = try #require(taken)
        #expect(rotation.tag == announced.tag, "announce, rotate, same bytes")
        draws.aired.append(announced.tag)
        #expect(schedule.take(1, wall: Self.wall + BlindTag.slotMilliseconds) == nil, "taken once")
        #expect(try air(&schedule, wall: Self.wall + BlindTag.slotMilliseconds).tag == Self.expected(slot: Self.slot + 1, restart: 1))
        #expect(noRepeat())
    }

    @Test func aMarkThatIsNotDurableAirsNothing() throws {
        var schedule = schedule()
        try air(&schedule, wall: Self.wall)
        for answer in [PresenceMarkWrite.refused, .notFull, .insideUnit, .failed] {
            store.answer = answer
            #expect(throws: TagSchedule.Failure.notDurable(answer)) {
                try schedule.next(key: Self.own(), wall: Self.wall + BlindTag.slotMilliseconds, marks: store, using: &draws.random)
            }
        }
        store.answer = .durable
        #expect(store.marks[1] == PresenceMark(slot: Self.slot, restart: 0), "the failed writes left the mark")
        #expect(try air(&schedule, wall: Self.wall + BlindTag.slotMilliseconds).tag == Self.expected(slot: Self.slot + 1, restart: 0))
    }

    @Test func aFailureComputingTheTagBurnsNoMark() throws {
        // The tag comes before the mark: an owner that makes no tag leaves the (slot, restart) unspent.
        var bad = TagSchedule(owner: Array(Self.me.bytes.dropLast()))
        #expect(throws: TagSchedule.Failure.noTag) {
            try bad.next(key: Self.own(), wall: Self.wall, marks: store, using: &draws.random)
        }
        #expect(store.marks.isEmpty, "nothing written")
        var schedule = schedule()
        #expect(try air(&schedule, wall: Self.wall).tag == Self.expected(slot: Self.slot, restart: 0))
    }

    @Test func aMarkThatWillNotReadAirsNothingAndIsReadAgain() throws {
        // `read` throws on failure (`TagSchedule.kt:67-68`): never "no mark", which would restart at the slot's restart 0.
        var schedule = schedule()
        try air(&schedule, wall: Self.wall)
        var fresh = self.schedule()
        store.failingReads = true
        #expect(throws: TagSchedule.Failure.readFailed) {
            try fresh.next(key: Self.own(), wall: Self.wall, marks: store, using: &draws.random)
        }
        #expect(throws: TagSchedule.Failure.readFailed) {
            try fresh.reserve(key: Self.own(), wall: Self.wall, marks: store, using: &draws.random)
        }
        #expect(store.reads == 3, "a failed read is not cached")
        store.failingReads = false
        #expect(try air(&fresh, wall: Self.wall).tag == Self.expected(slot: Self.slot, restart: 1), "the next restart, read afresh")
        #expect(noRepeat())
    }

    @Test func aMarkThatWouldMoveBackIsNeverWritten() {
        // The stores move a mark only forward, so a writer that read none by mistake is refused over the pair it would repeat.
        store.marks[1] = PresenceMark(slot: Self.slot, restart: 2)
        #expect(store.write(PresenceMark(slot: Self.slot, restart: 0), 1) == .refused)
        #expect(store.marks[1] == PresenceMark(slot: Self.slot, restart: 2))
    }

    @Test func theStoreIsReadOncePerGeneration() throws {
        var schedule = schedule()
        for index in 0..<3 {
            try air(&schedule, wall: Self.wall + Int64(index) * BlindTag.slotMilliseconds)
        }
        #expect(store.reads == 1)
    }

    @Test func onlyTheFirstAnnouncementForASlotReserves() throws {
        var schedule = schedule()
        let first = try schedule.reserve(key: Self.own(), wall: Self.wall, marks: store, using: &draws.random)
        let again = try schedule.reserve(key: Self.own(), wall: Self.wall + 20_000, marks: store, using: &draws.random)
        #expect(first.tag == again.tag, "a late link inside the lead is told the same tag")
        #expect(store.marks[1] == PresenceMark(slot: Self.slot + 1, restart: 0), "one restart spent")
    }

    @Test func anAnnouncementForALaterSlotReplacesTheHeldOne() throws {
        var schedule = schedule()
        let stale = try schedule.reserve(key: Self.own(), wall: Self.wall, marks: store, using: &draws.random)
        let later = try schedule.reserve(key: Self.own(), wall: Self.wall + BlindTag.slotMilliseconds, marks: store, using: &draws.random)
        #expect(later.tag == Self.expected(slot: Self.slot + 2, restart: 0), "the later slot's own tag, not the held one")
        let taken = schedule.take(1, wall: Self.wall + 2 * BlindTag.slotMilliseconds)
        #expect(taken?.tag == later.tag)
        #expect(stale.tag != taken?.tag, "the replaced reservation never airs")
    }

    @Test func aReservationTakenLateIsDroppedAndNextAirsAnUnusedPair() throws {
        var schedule = schedule()
        let announced = try schedule.reserve(key: Self.own(), wall: Self.wall, marks: store, using: &draws.random)
        #expect(schedule.take(1, wall: Self.wall + BlindTag.slotMilliseconds)?.tag == announced.tag, "taken in its slot")
        let late = try schedule.reserve(key: Self.own(), wall: Self.wall + BlindTag.slotMilliseconds, marks: store, using: &draws.random)
        #expect(schedule.take(1, wall: Self.wall + 3 * BlindTag.slotMilliseconds) == nil, "taken a slot late: dropped")
        #expect(schedule.take(1, wall: Self.wall + 2 * BlindTag.slotMilliseconds) == nil, "and gone")
        let next = try air(&schedule, wall: Self.wall + 3 * BlindTag.slotMilliseconds)
        #expect(next.tag == Self.expected(slot: Self.slot + 3, restart: 0))
        draws.aired += [announced.tag, late.tag]
        #expect(noRepeat())
    }

    @Test func droppedReservationsAreNeverTaken() throws {
        var schedule = schedule()
        let reserved = try schedule.reserve(key: Self.own(), wall: Self.wall, marks: store, using: &draws.random)
        schedule.dropReservations()
        #expect(schedule.take(1, wall: Self.wall + BlindTag.slotMilliseconds) == nil)
        #expect(store.marks[1] == PresenceMark(slot: Self.slot + 1, restart: 0), "the reservation's mark stays written")
        #expect(try air(&schedule, wall: Self.wall + BlindTag.slotMilliseconds).tag != reserved.tag)
    }

    @Test func aRandomTagCarriesThePrefixAndWritesNoMark() {
        let random = TagSchedule.randomTag(using: &draws.random)
        #expect(!random.resolvable)
        #expect(!random.stale)
        #expect(AdvertForm.hasTagPrefix(random.tag.bytes))
        #expect(store.marks.isEmpty)
    }
}
