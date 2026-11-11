import KnitCrypto
import KnitStore
import Testing

@testable import KnitMesh

/// ``AdvertRotation`` and ``StaleLatch``, ported from knit-next's `AdvertRotationTest` at `cad69c77b` (ADR 2026-11.prsp): the
/// slot turn on the wall clock, the announcement's lead, a late wake, a clock set back, and which own-key change restarts the
/// advert. Android's hold and ACL-settle cases have no counterpart: an iPhone runs no Coded window, hunt or settle, so its
/// turn never holds.
@Suite struct AdvertRotationTests {
    static let slot: Int64 = 2_000_000
    static let slotStart = slot * BlindTag.slotMilliseconds
    static let edge = slotStart + BlindTag.slotMilliseconds
    static let lead = AdvertRotation.leadMilliseconds

    let box = Box()
    var rotation: AdvertRotation {
        get { box.rotation }
        nonmutating set { box.rotation = newValue }
    }

    /// The turn a case drives.
    final class Box {
        var rotation = AdvertRotation()
    }

    @Test func nothingTurnsUntilABlindedFormIsOnTheAir() {
        #expect(rotation.next(wall: Self.edge + 1) == .wait(atWall: nil))
        #expect(rotation.nextEdge == nil)
        #expect(rotation.nextEdge == nil)
    }

    @Test func theTurnAnnouncesAtTheLeadThenRotatesAtTheEdgeOnTheAnnouncedTag() {
        rotation.onRotated(wall: Self.slotStart + 60_000)
        #expect(rotation.next(wall: Self.slotStart + 61_000) == .wait(atWall: Self.edge - Self.lead), "waits for the lead")
        let announceAt = Self.edge - Self.lead
        #expect(rotation.next(wall: announceAt) == .announce)
        rotation.onAnnounced(wall: announceAt)
        #expect(rotation.next(wall: announceAt + 1) == .wait(atWall: Self.edge), "the lead is past the 30 s minimum: the edge")
        #expect(rotation.next(wall: Self.edge) == .rotate(announced: true))
    }

    @Test func anAnnouncementLateInTheLeadStillGetsItsThirtySeconds() {
        rotation.onRotated(wall: Self.slotStart)
        let late = Self.edge - 10_000
        #expect(rotation.next(wall: late) == .announce)
        rotation.onAnnounced(wall: late)
        #expect(rotation.next(wall: Self.edge) == .wait(atWall: late + AdvertRotation.minLeadMilliseconds))
        #expect(rotation.next(wall: late + AdvertRotation.minLeadMilliseconds) == .rotate(announced: true))
    }

    @Test func aWakePastTheEdgeWithNothingAnnouncedRotatesAtOnceUnannounced() {
        rotation.onRotated(wall: Self.slotStart)
        #expect(rotation.next(wall: Self.edge + 40 * 60_000) == .rotate(announced: false))
    }

    @Test func anAnnouncementASlotLateIsNotTakenAndTheRotationIsUnannounced() {
        rotation.onRotated(wall: Self.slotStart)
        rotation.onAnnounced(wall: Self.edge - Self.lead)
        #expect(rotation.next(wall: Self.edge + BlindTag.slotMilliseconds + 1) == .rotate(announced: false))
    }

    @Test func aDroppedAnnouncementRotatesUnannounced() {
        rotation.onRotated(wall: Self.slotStart)
        rotation.onAnnounced(wall: Self.edge - Self.lead)
        rotation.dropAnnouncement()
        #expect(rotation.next(wall: Self.edge) == .rotate(announced: false))
    }

    @Test func aClockSetBackBelowTheSlotOnTheAirRotatesAtOnce() {
        rotation.onRotated(wall: Self.slotStart + 1)
        #expect(rotation.next(wall: Self.slotStart - 2 * 3_600_000) == .rotate(announced: false))
    }

    @Test func aRotationStartsTheNextTurnFromItsOwnSlot() {
        rotation.onRotated(wall: Self.slotStart)
        rotation.onRotated(wall: Self.edge + 5000)
        #expect(rotation.next(wall: Self.edge + 6000) == .wait(atWall: Self.edge + BlindTag.slotMilliseconds - Self.lead))
    }

    @Test func aStoppedWriterHasNothingToTurn() {
        rotation.onRotated(wall: Self.slotStart)
        rotation.onStopped()
        #expect(rotation.next(wall: Self.edge + 1) == .wait(atWall: nil))
    }

    static func key(_ generation: Int64, _ byte: UInt8? = nil) -> OwnPresenceKey {
        OwnPresenceKey(generation: generation, key: required(PresenceKey(bytes: [UInt8](repeating: byte ?? UInt8(generation), count: 32))))
    }

    @Test func whichOwnKeyChangeRestartsTheAdvert() {
        let cause = AdvertRotation.causeOfKeyChange
        // An equal value is no change; the generation already on the air is no change.
        #expect(cause(Self.key(5), Self.key(5), 5, true) == nil)
        #expect(cause(nil, Self.key(5), 5, false) == nil)
        #expect(cause(nil, nil, nil, false) == nil)
        // The session's first key after a bring-up that aired a random tag for want of one completes that bring-up.
        #expect(cause(nil, Self.key(5), nil, false) == .bringUp)
        // Every other change of the generation, nil among them, is a fresh restart.
        #expect(cause(Self.key(5), Self.key(6), 5, true) == .fresh)
        #expect(cause(Self.key(5), nil, 5, true) == .fresh)
        #expect(cause(nil, Self.key(6), nil, true) == .fresh)
        // The same generation with other bytes cannot come from the engine; it is still not the key on the air.
        #expect(cause(Self.key(5), Self.key(5, 9), 4, true) == .fresh)
    }

    @Test func aStaleMarkAsksOncePerGeneration() {
        var latch = StaleLatch()
        let answers = [(7, false), (7, true), (7, true), (7, false), (7, true), (8, true), (8, true)].map { latch.offer($0.0, stale: $0.1) }
        // Not stale; the first stale answer; latched for the generation; still latched, as the episode ends only with the
        // generation; a new generation clears the latch, once.
        #expect(answers == [false, true, false, false, false, true, false])
    }

    @Test func theNextAnnouncementIsDueAtTheLeadUntilItIsMade() {
        #expect(rotation.announceDueAt == nil, "nothing on the air")
        rotation.onRotated(wall: Self.slotStart)
        #expect(rotation.announceDueAt == Self.edge - Self.lead)
        rotation.onAnnounced(wall: Self.edge - Self.lead)
        #expect(rotation.announceDueAt == nil, "made")
        #expect(rotation.announced)
        rotation.onRotated(wall: Self.edge)
        #expect(!rotation.announced)
        #expect(rotation.announceDueAt == Self.edge + BlindTag.slotMilliseconds - Self.lead)
        #expect(rotation.nextEdge == Self.edge + BlindTag.slotMilliseconds)
    }
}
