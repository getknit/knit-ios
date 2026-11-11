import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// ``TagNextSends`` and ``LinkFormNotes``, ported from knit-next's `TagNextSendsTest` at `cad69c77b` (ADR 2026-11.prsp): the
/// predicate table, the receiver's per-link limit for a post-rotation send and a resend, a resend kept out of the window
/// before a due announcement, an announcement that never moves for a resend, and when a received `TAG_NEXT` becomes the
/// link's form. Android's probe case has no counterpart: this port writes no keepalive and probes nothing.
@Suite struct TagNextSendsTests {
    typealias Kind = TagNextSends<String>.Kind
    typealias Outcome = TagNextSends<String>.Outcome

    static let interval = TagNextSends<String>.minIntervalMilliseconds
    static let start: Int64 = 1_800_000_000_000
    static let slotStart = BlindTag.slotOf(wallMilliseconds: start) * BlindTag.slotMilliseconds
    static let edge = slotStart + BlindTag.slotMilliseconds

    let box = Box()

    /// The sends a case decides on.
    final class Box {
        var sends = TagNextSends<String>()
    }

    func send(
        _ kind: Kind, at wall: Int64, link: String = "x", eligible: Bool = true, hasKey: Bool = true, announceDueAt: Int64? = nil,
        announcing: Bool = false
    ) -> Outcome {
        box.sends.decide(
            link, kind: kind, eligible: eligible, hasKey: hasKey, wall: wall, announceDueAt: announceDueAt, announcing: announcing)
    }

    @Test func thePredicateTable() {
        #expect(TagNextSends<String>.eligible(proven: true, readsTags: true, hears: true))
        #expect(!TagNextSends<String>.eligible(proven: false, readsTags: true, hears: true), "unproven")
        #expect(!TagNextSends<String>.eligible(proven: true, readsTags: false, hears: true), "no CAP_BLIND_ADVERT")
        #expect(!TagNextSends<String>.eligible(proven: true, readsTags: true, hears: false), "blocked or departed")
        for kind in Kind.allCases {
            #expect(send(kind, at: Self.start, hasKey: false) == .noKey, "a random tag is never announced")
            #expect(send(kind, at: Self.start, eligible: false) == .ineligible)
        }
    }

    @Test func aResendKeepsTheReceiversLimitAndTheAnnouncementNeverMoves() {
        #expect(send(.resend, at: Self.start) == .sent)
        #expect(send(.resend, at: Self.start + Self.interval - 1) == .throttled, "inside the receiver's limit: it would be dropped")
        #expect(send(.resend, at: Self.start + Self.interval) == .sent)
        // An announcement due 90 s on: a resend now would be the one the receiver keeps, and the announcement dropped.
        let due = Self.start + 3 * Self.interval + 90_000
        #expect(send(.resend, at: due - 90_000, announceDueAt: due) == .beforeAnnounce)
        #expect(send(.announce, at: due) == .sent, "the announcement goes as due, whatever was resent")
        // A post-rotation send keeps the limit too, but not the announcement's window.
        #expect(send(.current, at: due + 1000) == .throttled)
        #expect(send(.current, at: due + Self.interval) == .sent)
    }

    @Test func eachLinkHasItsOwnLimitAndAnEndedLinkForgetsIt() {
        #expect(send(.current, at: Self.start, link: "a") == .sent)
        #expect(send(.current, at: Self.start, link: "b") == .sent)
        #expect(box.sends.sentWithin(wall: Self.start + 1))
        box.sends.forget("a")
        #expect(send(.current, at: Self.start + 1, link: "a") == .sent)
        box.sends.clear()
        #expect(!box.sends.sentWithin(wall: Self.start + 2))
        #expect(send(.resend, at: Self.start + 2, link: "b") == .sent)
    }

    @Test func anAnnouncementAppliesAtItsEdgeAndAResendAtOnce() {
        #expect(TagNextSends<String>.appliesAt(wall: Self.edge - AdvertRotation.leadMilliseconds) == Self.edge)
        #expect(TagNextSends<String>.appliesAt(wall: Self.edge - 5000) == Self.edge, "a late announcement too")
        let midSlot = Self.slotStart + 60_000
        #expect(TagNextSends<String>.appliesAt(wall: midSlot) == midSlot, "a resend names the form on the air now")
    }

    @Test func nothingButTheAnnouncementGoesWhileItStandsOrJustBeforeIt() {
        #expect(send(.announce, at: Self.start, announcing: true) == .sent)
        #expect(send(.resend, at: Self.start + 5 * Self.interval, link: "y", announcing: true) == .beforeAnnounce)
        #expect(send(.current, at: Self.start + 5 * Self.interval, link: "y", announcing: true) == .beforeAnnounce)
        let due = Self.start + 10 * Self.interval
        #expect(send(.current, at: due - Self.interval + 1, link: "z", announceDueAt: due) == .beforeAnnounce)
        #expect(send(.current, at: due - Self.interval - 1, link: "z", announceDueAt: due) == .sent)
    }

    static func tag(_ index: Int) -> NodeId {
        AdvertForm.tag(prefixing: UInt64(index), UInt64(index))
    }

    @Test func aThousandRecordsInOneSecondLeaveOneNoteThatAppliesOnce() {
        var notes = LinkFormNotes<String>()
        let first = Self.edge - 60_000
        var lastAt: Int64?
        for index in 0..<1000 {
            lastAt = notes.offer("fork", tag: Self.tag(index), wall: first + Int64(index))
        }
        #expect(notes.due(wall: .max).count == 1)
        #expect(lastAt == Self.edge)
        #expect(notes.nextDue == Self.edge)
        #expect(notes.due(wall: Self.edge - 1).isEmpty)
        let early = notes.take("fork", tag: Self.tag(999), wall: Self.edge - 1)
        #expect(!early, "not before its edge")
        let replaced = notes.take("fork", tag: Self.tag(0), wall: Self.edge)
        #expect(!replaced, "a replaced record never applies")
        #expect(notes.due(wall: Self.edge).map(\.tag) == [Self.tag(999)])
        let taken = notes.take("fork", tag: Self.tag(999), wall: Self.edge)
        let again = notes.take("fork", tag: Self.tag(999), wall: Self.edge)
        #expect(taken)
        #expect(!again, "taken once")
        #expect(notes.due(wall: .max).isEmpty)
        // A record that applies at once drops the note.
        let waits = notes.offer("fork", tag: Self.tag(1), wall: first)
        let atOnce = notes.offer("fork", tag: Self.tag(2), wall: Self.slotStart + 1000)
        #expect(waits == Self.edge)
        #expect(atOnce == nil)
        #expect(notes.due(wall: .max).isEmpty)
        #expect(notes.nextDue == nil)
    }

    @Test func aNoteWhoseLinkEndedNeverApplies() {
        var notes = LinkFormNotes<String>()
        _ = notes.offer("gone", tag: Self.tag(1), wall: Self.edge - 60_000)
        _ = notes.offer("other", tag: Self.tag(2), wall: Self.edge - 60_000)
        notes.forget("gone")
        #expect(notes.due(wall: Self.edge).map(\.link) == ["other"])
        notes.clear()
        #expect(notes.due(wall: .max).isEmpty)
    }

    @Test func onlyAnAcceptedAnnouncementIsNoted() {
        let all: [AdvertAliases<String>.ClaimOutcome] = [
            .recorded, .pending, .hinted, .redundant, .contradicted, .contested, .ignored, .full, .rateLimited,
        ]
        #expect(all.filter { LinkFormNotes<String>.notes($0) } == [.pending, .redundant])
    }
}
