import KnitCrypto
import KnitStore
import KnitWire

/// Our own presence keys' rules (ADR 2026-11.prsp, "Our own keys"), pure: the send half of knit-next's `PresenceKeyPolicy`
/// (`mesh/crypto/PresenceKeyPolicy.kt:21-213` at `cad69c77b`), with Android's constants.
///
/// **Own keys.** At most three rows: the previous key, the current one (the newest activated) and the next one (never
/// activated, never aired, handed to contacts ahead so a weekly rotation is seamless). Each names its audience, the direct
/// contacts it may be handed to. ``due(rows:direct:now:clockAdvanceAllowed:)`` is a function of those rows, a fresh read of
/// the direct contacts and the wall clock alone: a row's stamps never feed back as a generation, so a corrected clock
/// rotates once, then is quiet.
///
/// **Generations** are `max(last + 1, now)`, the add checked (``nextGeneration(last:now:)``): an order only, never a time.
extension PresenceKeyPolicy {
    /// A weekly rotation: the next key becomes the current one once the current one has been aired this long (`WEEK_MS`).
    static let weekMilliseconds: Int64 = 604_800_000
    /// How long after its activation a current key may still take a new contact (`DAY_MS`): a contact accepted later never
    /// gets a key whose tags aired for days before. Also the floor between two clock or mark advances, on a clock that
    /// keeps running while the phone sleeps, so a spoofed wall clock cannot burn a generation every heal.
    static let dayMilliseconds: Int64 = 86_400_000
    /// How far past the wall clock a current key's activation may sit before it reads as a clock that ran ahead and was
    /// corrected (`CLOCK_SLACK_MS`): an hour, so a minute of correction never rotates.
    static let clockSlackMilliseconds: Int64 = 3_600_000
    /// A last generation further than this past the clock is clamped to the clock at a reinstall (`CLAMP_AHEAD_MS`): 365
    /// days.
    static let clampAheadMilliseconds: Int64 = 31_536_000_000

    /// One of our key rows as the policy reads it.
    typealias Own = OwnPresenceKeyRecord

    /// The rows read as the three roles (`Keys`, `:63-67`).
    struct Keys: Equatable {
        let previous: Own?
        let current: Own?
        let next: Own?
    }

    /// `rows` as previous, current and next (`keysOf`, `:70-77`): the newest activated is current, the one before it
    /// previous, and the newest never activated next.
    static func keysOf(_ rows: [Own]) -> Keys {
        let activated = rows.filter { $0.activatedAt != nil }.sorted { $0.generation > $1.generation }
        return Keys(
            previous: activated.count > 1 ? activated[1] : nil,
            current: activated.first,
            next: rows.filter { $0.activatedAt == nil }.max { $0.generation < $1.generation }
        )
    }

    /// Why an ``Due/advance(_:)`` is due (`AdvanceCause`, `:80-89`).
    enum AdvanceCause: Sendable, Equatable {
        /// The current key has aired a week.
        case weekly
        /// The current key was activated more than ``clockSlackMilliseconds`` ahead of the clock: a clock that ran ahead,
        /// corrected.
        case clock
        /// The advertiser's mark under the current key sits past the contact window's lead.
        case mark
    }

    /// What ``due(rows:direct:now:clockAdvanceAllowed:)`` asks for next (`Due`, `:92-121`). The engine applies one and asks
    /// again, until ``nothing``.
    enum Due: Sendable, Equatable {
        /// Nothing (`Due.None`): the keys are as they should be.
        case nothing
        /// No current key: mint a current and a next key, each for the direct contacts read now.
        case mint
        /// A key's audience holds someone who is no longer a direct contact: discard the next key and mint a new current and
        /// next. Never rate-limited.
        case fresh
        /// The next key becomes the current one, and a new next key is minted.
        case advance(AdvanceCause)
        /// No next key: mint one.
        case mintNext
        /// New direct contacts join the next key's audience (`toNext`), and the current key's (`toCurrent`) only while it
        /// was activated under a day ago. No rotation.
        case grow(toNext: Set<NodeId>, toCurrent: Set<NodeId>)
    }

    /// The next own-key step, in the brief's order (`due`, `:129-155`): no current is ``Due/mint``; a shrink
    /// ``Due/fresh``; a week a weekly ``Due/advance(_:)``; a corrected clock or a stale mark an advance, only while
    /// `clockAdvanceAllowed` (the engine's once-a-day floor); no next ``Due/mintNext``; a new contact ``Due/grow(toNext:toCurrent:)``.
    static func due(rows: [Own], direct: Set<NodeId>, now: Int64, clockAdvanceAllowed: Bool) -> Due {
        let keys = keysOf(rows)
        guard let current = keys.current, let activatedAt = current.activatedAt else {
            return .mint
        }
        let next = keys.next
        if !current.audience.isSubset(of: direct) || next.map({ !$0.audience.isSubset(of: direct) }) == true {
            return .fresh
        }
        // Kotlin's plain subtractions: a wall clock and an activation stamp never come near the 64-bit edges.
        if now >= activatedAt, now &- activatedAt >= weekMilliseconds {
            return .advance(.weekly)
        }
        if clockAdvanceAllowed {
            if activatedAt &- now > clockSlackMilliseconds {
                return .advance(.clock)
            }
            if let mark = current.mark, mark.slot &- BlindTag.slotOf(wallMilliseconds: now) > BlindTag.windowAheadSlots {
                return .advance(.mark)
            }
        }
        guard let next else {
            return .mintNext
        }
        let toNext = direct.subtracting(next.audience)
        guard !toNext.isEmpty else {
            return .nothing
        }
        let age = now &- activatedAt
        let toCurrent = (-clockSlackMilliseconds..<dayMilliseconds).contains(age) ? toNext.subtracting(current.audience) : []
        return .grow(toNext: toNext, toCurrent: toCurrent)
    }

    /// The generation a mint takes, `max(last + 1, now, 1)`, or `nil` when `last + 1` overflows and nothing may be minted
    /// (`nextGeneration`, `:158-164`).
    static func nextGeneration(last: Int64, now: Int64) -> Int64? {
        let (after, overflow) = last.addingReportingOverflow(1)
        guard !overflow else {
            return nil
        }
        return max(after, now, 1)
    }

    /// The keys `peer` is owed under `keys` (`owed`, `:184-187`): the current key if it is in its audience, the next one if
    /// it is in that one's, lowest generation first. The caller checks the link, the session and the capabilities.
    static func owed(_ peer: NodeId, keys: Keys) -> [Own] {
        [keys.current, keys.next].compactMap(\.self).filter { $0.audience.contains(peer) }
    }

    /// Who left one of our keys' audiences while a kept generation was live (`departed`, `:198-201`): everyone a kept row
    /// names who is not in `direct`, the direct contacts read now. Settled, that is the previous key's audience less the
    /// direct contacts: the departures that caused the last fresh pair. It empties when that generation goes.
    static func departed(rows: [Own], direct: Set<NodeId>) -> Set<NodeId> {
        rows.reduce(into: Set<NodeId>()) { $0.formUnion($1.audience) }.subtracting(direct)
    }

    /// Whether a linked peer may be sent our next advert tag, `TAG_NEXT` (`hearsTagNext`, `:209-213`): neither `blocked`
    /// nor `departed`. An input not read yet this session, `nil`, answers no: a send refused costs a linked peer one dial
    /// of an unannounced tag, while a send to someone just blocked hands them the tag the fresh rotation was for.
    static func hearsTagNext(_ peer: NodeId, blocked: Set<NodeId>?, departed: Set<NodeId>?) -> Bool {
        guard let blocked, let departed else {
            return false
        }
        return !blocked.contains(peer) && !departed.contains(peer)
    }
}
