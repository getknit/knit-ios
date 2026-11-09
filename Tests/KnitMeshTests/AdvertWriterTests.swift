import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// ``AdvertWriter`` and ``TagChoice``, ported from knit-next's `AdvertWriterTest` at `cad69c77b` (ADR 2026-11.prsp): while
/// blinding, no payload handed to the radio carries the node id in bytes 1–16; nothing airs while a tag is pending; a mark
/// that is not durable yields a random tag, never the id; a snapshot the radio went down under is never pushed again.
/// Android's cases about advertising sets (retiring, Coded power) have no counterpart: an iPhone has one GATT value.
@Suite struct AdvertWriterTests {
    static let me = LinkRig.high
    static let wall: Int64 = 1_800_000_000_000
    static let key = OwnPresenceKey(generation: 4, key: required(PresenceKey(bytes: [UInt8](repeating: 9, count: 32))))

    let bench = Bench()
    var store: FakeMarks { bench.store }
    var pushed: [AdvertPayload] { bench.pushed }

    /// The writer, the schedule and the generator a case drives, and every payload a push handed over.
    final class Bench {
        var writer = AdvertWriter(localId: me)
        var schedule = TagSchedule(owner: me.bytes)
        let store = FakeMarks()
        var random = SeededGenerator(seed: 3)
        var pushed: [AdvertPayload] = []
    }

    static func encode(_ aired: AdvertWriter.Aired) -> AdvertPayload {
        AdvertPayload(
            capabilities: .local,
            advertised: aired.form.advertised,
            digestCue: aired.form.blinded ? 0 : 0x1234,
            psm: aired.psm,
            flags: AdvertPayload.writtenFlags(dialsGattPeers: true, blinded: aired.form.blinded, seals: false)
        )
    }

    @discardableResult
    func push(_ encode: (AdvertWriter.Aired) -> AdvertPayload = Self.encode) -> Bool {
        guard let payload = bench.writer.push(encode) else {
            return false
        }
        bench.pushed.append(payload)
        return true
    }

    func choose(held: OwnPresenceKey? = key, live: OwnPresenceKey? = key, announced: Bool = false, wall: Int64 = wall) -> TagChoice.Choice {
        TagChoice.choose(&bench.schedule, held: held, live: live, announced: announced, wall: wall, marks: store, using: &bench.random)
    }

    func noIdWhileBlinded() -> Bool {
        pushed.allSatisfy { !$0.blinded || $0.advertised != Self.me }
    }

    @Test func aBlindingBringUpAirsNothingUntilItsTagIsInstalled() {
        bench.writer.up(pendingTag: true)
        #expect(!push(), "a push while the tag is pending hands nothing over")
        #expect(bench.writer.pushWanted)
        let choice = choose()
        bench.writer.install(form: choice.form, previous: nil, psm: 0x81)
        #expect(!bench.writer.pending)
        #expect(push())
        let payload = pushed.first
        #expect(payload?.blinded == true)
        #expect(payload?.digestCue == 0)
        let slot = BlindTag.slotOf(wallMilliseconds: Self.wall)
        #expect(payload?.advertised == BlindFixture.tag(Self.key.key, owner: Self.me, slot: slot))
        #expect(payload?.psm == 0x81)
        #expect(noIdWhileBlinded())
    }

    @Test func aMarkThatIsNotDurableYieldsARandomTagNeverTheId() {
        store.answer = .refused // a fresh pair demoted the generation between the key change and the write
        bench.writer.up(pendingTag: true)
        let choice = choose()
        #expect(choice.source == .markFailed)
        #expect(choice.generation == Self.key.generation)
        #expect(!choice.resolvable)
        bench.writer.install(form: choice.form, previous: nil, psm: 0x81)
        #expect(push())
        #expect(pushed.first?.blinded == true)
        #expect(pushed.first.map { AdvertForm.hasTagPrefix($0.advertised.bytes) } == true, "a prefixed random tag")
        #expect(noIdWhileBlinded())
    }

    @Test func aBlindedSnapshotRefusesAPayloadThatNamesTheId() {
        bench.writer.up(pendingTag: true)
        bench.writer.install(form: choose().form, previous: nil, psm: 0x81)
        // An encoder that builds from the node id: refused, counted, nothing aired.
        let fromId = { (aired: AdvertWriter.Aired) in
            AdvertPayload(
                capabilities: .local,
                advertised: Self.me,
                digestCue: 0,
                psm: aired.psm,
                flags: AdvertPayload.writtenFlags(dialsGattPeers: true, blinded: true, seals: false)
            )
        }
        #expect(!push(fromId))
        #expect(bench.writer.clearRefused == 1)
        // One that drops the flag over the tag, which a build at the pin would read as an id: refused too.
        let unflagged = { (aired: AdvertWriter.Aired) in
            AdvertPayload(capabilities: .local, advertised: aired.form.advertised, digestCue: 0, psm: aired.psm, flags: 0)
        }
        #expect(!push(unflagged))
        #expect(bench.writer.clearRefused == 2)
        #expect(pushed.isEmpty)
    }

    @Test func aClearSnapshotAirsOnlyTheIdWithoutTheFlag() {
        bench.writer.up(pendingTag: false)
        #expect(!push(), "nothing installed yet")
        bench.writer.install(form: .clear(Self.me), previous: nil, psm: 0x80)
        #expect(push())
        #expect(pushed.last?.advertised == Self.me)
        #expect(pushed.last?.blinded == false)
        let tagged = { (aired: AdvertWriter.Aired) in
            AdvertPayload(
                capabilities: .local,
                advertised: Self.me,
                digestCue: 0,
                psm: aired.psm,
                flags: AdvertPayload.writtenFlags(dialsGattPeers: true, blinded: true, seals: false)
            )
        }
        #expect(!push(tagged), "the id under the flag")
        let another = { (aired: AdvertWriter.Aired) in
            AdvertPayload(capabilities: .local, advertised: LinkRig.low, digestCue: 0, psm: aired.psm, flags: 0)
        }
        #expect(!push(another), "another id")
        #expect(bench.writer.clearRefused == 2)
    }

    @Test func aRotationAirsNothingUntilItsInstallAndEachFormIsItsOwnSnapshot() {
        bench.writer.up(pendingTag: false)
        bench.writer.install(form: .clear(Self.me), previous: nil, psm: 0x80)
        push()
        // The switch flips on: a rotation.
        bench.writer.begin()
        #expect(!push(), "a push mid-rotation hands nothing over")
        #expect(bench.writer.pushWanted)
        let first = choose().form
        bench.writer.install(form: first, previous: .clear(Self.me), psm: 0x80)
        #expect(bench.writer.aired?.previous == .clear(Self.me))
        push()
        // The slot edge.
        bench.writer.begin()
        let second = choose(wall: Self.wall + BlindTag.slotMilliseconds).form
        bench.writer.install(form: second, previous: first, psm: 0x80)
        push()
        #expect(pushed.map(\.advertised) == [Self.me, first.advertised, second.advertised])
        #expect(noIdWhileBlinded())
        #expect(bench.writer.installs == 3)
        #expect(bench.writer.aired?.installs == 3)
    }

    @Test func aBringUpNeverRestartsTheLastSessionsForm() {
        bench.writer.up(pendingTag: true)
        bench.writer.install(form: choose().form, previous: nil, psm: 0x81)
        push()
        bench.writer.down()
        #expect(!push(), "down: nothing")
        bench.writer.up(pendingTag: true)
        #expect(!push(), "the stopped snapshot is not pushed again with its old tag")
        #expect(pushed.count == 1)
    }

    @Test func aNewPSMKeepsTheFormAndItsStamp() {
        bench.writer.repoint(psm: 0x90)
        #expect(bench.writer.aired == nil, "nothing to repoint")
        bench.writer.up(pendingTag: false)
        bench.writer.install(form: .clear(Self.me), previous: nil, psm: 0x80)
        bench.writer.repoint(psm: 0x80)
        bench.writer.repoint(psm: 0xC1)
        #expect(bench.writer.aired == AdvertWriter.Aired(form: .clear(Self.me), previous: nil, psm: 0xC1, installs: 1))
        #expect("\(bench.writer.aired.map { "\($0)" } ?? "")".hasPrefix("Aired(Form("))
    }

    @Test func aMarkThatWillNotReadYieldsARandomTagNeverTheId() {
        store.failingReads = true
        let choice = choose()
        #expect(choice.source == .markFailed)
        #expect(!choice.resolvable)
        #expect(choice.form.blinded && choice.form.advertised != Self.me)
        #expect(store.marks.isEmpty)
    }

    @Test func noKeyAirsARandomPrefixedTag() {
        let choice = choose(held: nil, live: nil)
        #expect(choice.source == .noKey)
        #expect(choice.generation == nil)
        #expect(choice.form.blinded)
        #expect(AdvertForm.hasTagPrefix(choice.form.advertised.bytes))
        #expect(store.marks.isEmpty, "no mark written for a random tag")
    }

    @Test func aKeyTheEngineMovedPastAirsNothingUnderItAndDropsItsReservation() throws {
        let reserved = try bench.schedule.reserve(key: Self.key, wall: Self.wall, marks: store, using: &bench.random)
        let fresh = OwnPresenceKey(generation: 5, key: required(PresenceKey(bytes: [UInt8](repeating: 2, count: 32))))
        // At the edge the engine already holds generation 5; the link manager has not taken it in yet.
        let choice = choose(live: fresh, announced: true, wall: Self.wall + BlindTag.slotMilliseconds)
        #expect(choice.source == .keyMoved)
        #expect(choice.form.advertised != reserved.tag)
        #expect(
            bench.schedule.take(Self.key.generation, wall: Self.wall + BlindTag.slotMilliseconds) == nil, "the reservation went unaired")
    }

    @Test func anAnnouncedRotationAirsExactlyTheReservedTag() throws {
        let reserved = try bench.schedule.reserve(key: Self.key, wall: Self.wall, marks: store, using: &bench.random)
        let choice = choose(announced: true, wall: Self.wall + BlindTag.slotMilliseconds)
        #expect(choice.source == .announced)
        #expect(choice.form.advertised == reserved.tag)
        #expect("\(choice)" == "Choice(source: announced, resolvable: true)", "its printing names no tag")
    }

    @Test func anAnnouncementThatMissedItsSlotFallsThroughToTheSlot() throws {
        _ = try bench.schedule.reserve(key: Self.key, wall: Self.wall, marks: store, using: &bench.random)
        let choice = choose(announced: true, wall: Self.wall + 2 * BlindTag.slotMilliseconds)
        #expect(choice.source == .slotted)
        #expect(choice.resolvable)
    }

    @Test func anUnannouncedRotationPassesAReservationByUnaired() throws {
        let reserved = try bench.schedule.reserve(key: Self.key, wall: Self.wall, marks: store, using: &bench.random)
        let choice = choose(announced: false, wall: Self.wall + BlindTag.slotMilliseconds)
        #expect(choice.source == .slotted)
        #expect(choice.form.advertised != reserved.tag, "the reserved slot's mark is spent: the next restart airs")
        #expect(choice.resolvable)
    }
}
