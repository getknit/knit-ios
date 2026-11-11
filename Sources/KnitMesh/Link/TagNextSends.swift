import KnitCrypto
import KnitWire

/// Who is sent our advertised form over a link, and when (`TagNextSends`, `TagNextSends.kt:31-121` at knit-next `cad69c77b`;
/// ADR 2026-11.prsp, "The link"). Pure, keyed by link, on the wall clock the caller passes, single-threaded on the `Mesh`
/// actor.
///
/// Three sends, one ``Kind`` each:
/// - ``Kind/announce``, the lead announcement of the coming slot's reserved tag, and the same tag to a link that comes up
///   while it stands. It never moves and is never throttled: the resends keep out of its way instead.
/// - ``Kind/current``, the form just aired after a rotation nobody was told of (a late wake, a key change, a flip), once per
///   link, so linked strangers do not dial the new tag.
/// - ``Kind/resend``, `RefuseHeld`'s answer to a dialer that missed a rotation.
///
/// The receiver keeps one `TAG_NEXT` per link per ``minIntervalMilliseconds`` and drops the rest, so a current or a resend goes
/// only when none went to that link inside it, never inside it before a due announcement (which would then be the one
/// dropped), and never while an announcement stands, which the receiver holds pending and another form would replace.
///
/// Every send needs the link ``eligible(proven:readsTags:hears:)`` and a key held: a random tag is never announced.
internal struct TagNextSends<L: Hashable> {
    /// The receiver's per-link limit (`MIN_INTERVAL_MS`, `:98`; `AdvertAliases`' `tagNextMinIntervalMilliseconds`).
    static var minIntervalMilliseconds: Int64 { TagNextTiming.minIntervalMilliseconds }

    /// How far before a slot edge a received `TAG_NEXT` reads as the announcement of the coming slot (`ANNOUNCE_WINDOW_MS`,
    /// `:108`).
    static var announceWindowMilliseconds: Int64 { TagNextTiming.announceWindowMilliseconds }

    /// Which send.
    enum Kind: Hashable, CaseIterable {
        case announce
        case current
        case resend
    }

    /// What ``decide(_:kind:eligible:hasKey:wall:announceDueAt:announcing:)`` made of a send; all but ``sent`` are counted as
    /// refusals.
    enum Outcome: Hashable, CaseIterable {
        case sent
        case noKey
        case ineligible
        case throttled
        case beforeAnnounce
    }

    private var lastSent: [L: Int64] = [:]

    /// Whether a link may be sent a form at all: proven, its HELLO carrying `CAP_BLIND_ADVERT`, and its peer neither blocked
    /// nor departed now (``PresenceKeySource/hearsTagNext``, read at the send, never at link-up).
    static func eligible(proven: Bool, readsTags: Bool, hears: Bool) -> Bool {
        proven && readsTags && hears
    }

    /// Whether a `kind` send to `link` goes at `wall` (recorded as sent when it does), given its eligibility, whether a key
    /// is held, when the next announcement is due (wall clock) and whether one stands now (`decide`, `:47-77`).
    mutating func decide( // swiftlint:disable:this function_parameter_count - the send's facts, each from its own source
        _ link: L, kind: Kind, eligible: Bool, hasKey: Bool, wall: Int64, announceDueAt: Int64?, announcing: Bool
    ) -> Outcome {
        let interval = Self.minIntervalMilliseconds
        let outcome: Outcome
        if !hasKey {
            outcome = .noKey
        } else if !eligible {
            outcome = .ineligible
        } else if kind == .announce {
            outcome = .sent
        } else if announcing {
            outcome = .beforeAnnounce
        } else if let last = lastSent[link], (0..<interval).contains(wall - last) {
            outcome = .throttled
        } else if let due = announceDueAt, (0..<interval).contains(due - wall) {
            outcome = .beforeAnnounce
        } else {
            outcome = .sent
        }
        if outcome == .sent {
            lastSent[link] = wall
        }
        return outcome
    }

    /// Whether any link held was sent a form within the limit before `wall`: a forced rotation's send would be throttled.
    func sentWithin(wall: Int64) -> Bool {
        lastSent.values.contains { (0..<Self.minIntervalMilliseconds).contains(wall - $0) }
    }

    /// The link ended.
    mutating func forget(_ link: L) {
        lastSent[link] = nil
    }

    /// Every link's (the radio down, a stop).
    mutating func clear() {
        lastSent.removeAll()
    }

    /// When a `TAG_NEXT` received at `wall` becomes the link's form (`appliesAt`, `:116-119`): at the coming slot edge for
    /// one received within ``announceWindowMilliseconds`` before it, at once for any other.
    static func appliesAt(wall: Int64) -> Int64 {
        let edge = (BlindTag.slotOf(wallMilliseconds: wall) + 1) * BlindTag.slotMilliseconds
        return edge - wall <= announceWindowMilliseconds ? edge : wall
    }
}

/// ``TagNextSends``' times, apart from the generic type, which holds no stored constant.
internal enum TagNextTiming {
    /// The receiver's per-link limit: two minutes.
    static let minIntervalMilliseconds: Int64 = 120_000
    /// A minute past the announcement's lead.
    static let announceSlackMilliseconds: Int64 = 60_000
    /// The announcement's lead and that minute of slack.
    static let announceWindowMilliseconds: Int64 = AdvertRotation.leadMilliseconds + announceSlackMilliseconds
}

/// The form a peer's accepted `TAG_NEXT` makes its link's, one note per link (`LinkFormNotes`, `TagNextSends.kt:130-172`): a
/// later record replaces the note, so a linked fork sending records at link rate keeps one note, never one per record.
/// ``offer(_:tag:wall:)`` says when the note applies; ``take(_:tag:wall:)`` confirms, at that time, that the note is still
/// that link's and that tag. Pure.
internal struct LinkFormNotes<L: Hashable> {
    private var notes: [L: (tag: NodeId, at: Int64)] = [:]

    /// The earliest wall-clock instant a note applies at, or `nil` with none.
    var nextDue: Int64? { notes.values.map(\.at).min() }

    /// A `TAG_NEXT` naming `tag`, received on `link` at `wall` and accepted by the resolver: `nil` when it applies now (any
    /// note the link held goes), else the wall-clock instant its note applies at.
    mutating func offer(_ link: L, tag: NodeId, wall: Int64) -> Int64? {
        let at = TagNextSends<L>.appliesAt(wall: wall)
        guard at > wall else {
            notes[link] = nil
            return nil
        }
        notes[link] = (tag, at)
        return at
    }

    /// Whether `link`'s note is still `tag` and due at `wall`: then it is taken, and applies.
    mutating func take(_ link: L, tag: NodeId, wall: Int64) -> Bool {
        guard let note = notes[link], note.tag == tag, wall >= note.at else {
            return false
        }
        notes[link] = nil
        return true
    }

    /// The notes due at `wall`, link and tag, in no order: each is still to be confirmed with ``take(_:tag:wall:)``.
    func due(wall: Int64) -> [(link: L, tag: NodeId)] {
        notes.filter { $0.value.at <= wall }.map { ($0.key, $0.value.tag) }
    }

    /// The link ended.
    mutating func forget(_ link: L) {
        notes[link] = nil
    }

    /// Every link's.
    mutating func clear() {
        notes.removeAll()
    }

    /// Whether a resolver answer to a `TAG_NEXT` is noted: held pending, or already a contact's key's answer
    /// (`LinkFormWaits.notes`, `TagNextSends.kt:239-240`).
    static func notes<M: Hashable>(_ outcome: AdvertAliases<M>.ClaimOutcome) -> Bool {
        outcome == .pending || outcome == .redundant
    }
}
