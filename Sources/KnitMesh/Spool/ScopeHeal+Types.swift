import KnitStore
import KnitWire

/// The values a heal loop reads and answers with: custody's read, the caller's settlement, the outputs, the counts, a
/// scope's state across connections, and a round and its step.
extension ScopeHeal {
    /// What the caller read from custody for a round.
    enum Custody: Sendable {
        /// Every live frame, as ``KnitStore/CustodyStore/liveFrames(now:)`` answers.
        case frames([CarriedFrame])
        /// The read failed. The round is skipped, never run as though custody were empty, which would pull everything.
        case unreadable
    }

    /// How the caller's turn with a candidate ended.
    enum Settlement: Sendable, Equatable {
        /// Its signature did not verify against the key the engine's `verifierBundle` names, or there is none: a pulled
        /// blob is quarantined. It is not counted against the relay, since anyone who knows the scope could have pushed it
        /// or the spool minted it; the hourly budget bounds what such blobs cost.
        case unopenable
        /// The engine's carry gate refused the frame for its own bytes (a DM not sealed, a group frame its roster does not
        /// derive): a pulled blob is quarantined. Never for anything about this phone's state.
        case refusedByCarry
        /// The engine could not take it for a reason of its own (a store unit that failed): the claim is released and
        /// nothing else, so a later round may pull it again. No quarantine, and nothing counted against the relay.
        case notTaken
        /// The engine took it, or its router dropped it as a frame already seen (a second relay's copy included).
        /// `keptLive` is whether custody holds the frame live in the same turn (`custody.frame(id, now:) != nil`, never
        /// `contains`): when it does not, the blob is accounted (C-9.6-1), never quarantined.
        case delivered(keptLive: Bool)
    }

    /// What the heal asks of its caller.
    enum Output: Sendable {
        /// A blob that opened and passed the rule: verify its signature, deliver it, and settle it.
        case candidate(ScopeCandidate)
        /// Mine this stamp off the engine and answer ``ScopeHeal/stampMined(_:counter:session:now:)``.
        case mine(SpoolMiningRequest)
        /// Stop mining this stamp: its scope left the table.
        case cancelMining(SpoolMiningRequest)
    }

    /// What the heal has done, for `status` and a log line per interval.
    struct Counts: Sendable, Equatable {
        /// `list` records sent.
        var listings = 0
        /// Listings refused whole for naming more ids than a conforming spool can (`OVERLONG_LISTING`).
        var overlongListings = 0
        /// Pushes the spool stored.
        var pushed = 0
        /// Ids put into an invalid set.
        var quarantined = 0
        /// Ids put into an accounted set.
        var accounted = 0
        /// Ids put into an unpushable set.
        var unpushable = 0
        /// Arrivals already claimed on the connection.
        var duplicates = 0
        /// Live events naming an id already accounted or quarantined, dropped unclaimed.
        var replays = 0
        /// Stamps refused for want of the day's mining allowance.
        var stampsCapped = 0
        /// Rounds skipped because custody could not be read.
        var unreadableRounds = 0
        /// Ids a round left unpulled because the hour's byte budget was spent.
        var budgetDeferred = 0
        /// Sessions ended as ``SpoolFault/unopenable``.
        var faults = 0
        /// Scopes parked after a `quota` or `pow` refusal.
        var parks = 0
    }

    /// One scope's state across connections.
    struct ScopeState: Sendable {
        var accounted = BoundedIDSet()
        var invalid = BoundedIDSet()
        var unpushable = BoundedIDSet()
        /// The unpushable ids a push refusal put there (`too_large`, `bad_id`, past `maxRecord`), which a listing never
        /// takes back out; the rest went in for a listing reason and leave when it lapses.
        var stickyUnpushable: Set<SpoolID> = []
        /// The UTC day stamps were last asked for, and how many that day.
        var minedDay: Int64?
        var minedToday = 0
        /// Until when the scope is neither subscribed nor healed, on the monotonic clock.
        var parkedUntil: Int64?
        /// Whether the spool asked a stamp of it (`stampDemanded`); a `digest` clears it.
        var stampDemanded = false
        var stamp: PowStamp?
        /// When it last healed, on the monotonic clock.
        var lastHealAt: Int64?
        /// The local fold the last heal compared (`localDigests`), for `status` and the tests.
        var localFold: UInt64?
        /// Whether the next heal lists whatever the fold says: a candidate the engine could not take (``Settlement/notTaken``)
        /// left the spool's anchor folding a blob custody lacks only when a pull named it, and a live `event` moves no
        /// anchor, so a fold equal to the anchor would never list it again (ADR 2026-11.adrq, P4a).
        var listOwed = false
    }

    /// A round: the scopes still due, and the one custody read that serves them all (`healAll`, `:1896-1899`).
    struct Round: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        var due: [SpoolID]
        let frames: [CarriedFrame]

        var description: String { "round: \(due.count) scopes due, \(frames.count) frames" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    /// One scope's heal inside a round (`reconcileListing`, `:1945-1992`).
    struct Step: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        enum Phase: Sendable {
            case listing(request: Int64)
            case pulling(request: Int64)
            case pushing(request: Int64, blob: HeldBlob, stamped: Bool)
            /// A push refused `rate`, waited out until the instant given, at most 5 s.
            case rateWait(until: Int64)
        }

        let scope: SpoolScope
        let held: [HeldBlob]
        let heldIds: Set<SpoolID>
        /// The anchor the LIST was sent against (#322): the re-anchor writes only over it.
        let listedAgainst: UInt64
        /// The accounted and invalid sets before the LIST: a listing prunes only what it could have seen.
        let accountedBefore: Set<SpoolID>
        let invalidBefore: Set<SpoolID>
        var phase: Phase
        var listed: [SpoolID] = []
        var listedSet: Set<SpoolID> = []
        var tombstones: Set<SpoolID> = []
        var batches: [[SpoolID]] = []
        var pushes: [HeldBlob] = []
        var gone: Set<SpoolID> = []
        var pushed: [SpoolID] = []
        var learnt = false
        /// The worst case the pull in flight charged to the hour, and the bytes its blobs used of it.
        var pullReserved = 0
        var pullReceived = 0

        var description: String { "step: \(scope), \(held.count) held, \(listed.count) listed, \(pushed.count) pushed" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }
}
