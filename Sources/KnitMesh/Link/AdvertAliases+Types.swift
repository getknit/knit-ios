import KnitCrypto
import KnitWire

/// ``AdvertAliases``' tunables (`Config`, `AdvertAliases.kt:105-127` at knit-next `cad69c77b`).
internal struct AdvertAliasesConfiguration {
    /// The rotation period: a tag's slot, 15 minutes.
    var rotationPeriodMilliseconds = BlindTag.slotMilliseconds
    /// The presence tracker's linger past a peer's last sighting.
    var presenceLingerMilliseconds: Int64 = 90_000
    /// The longest a contact's replaced key is still listed when no tag under its successor is heard: one key
    /// generation, the weekly rotation (`KEY_GENERATION_MS`).
    var previousKeyMaxMilliseconds: Int64 = 604_800_000
    /// Claims held at once.
    var maxClaims = 128
    /// One `TAG_NEXT` per link per this window.
    var tagNextMinIntervalMilliseconds: Int64 = 120_000

    /// Announced tags, and voids, held per claim.
    static let entriesPerClaim = 2
    /// Stale deadlines may outnumber live entries by this factor, plus ``queueFloor``, before the queue is rebuilt.
    static let queueSlack = 4
    static let queueFloor = 256

    /// One rotation period plus the presence linger: 990 s.
    var claimLifetimeMilliseconds: Int64 { rotationPeriodMilliseconds + presenceLingerMilliseconds }
    /// The cap on announced tags, and on voids.
    var entryCap: Int { Self.entriesPerClaim * maxClaims }
}

/// ``AdvertAliases``' answers, outcomes, counters and table entries (`AdvertAliases.kt:129-299` at knit-next `cad69c77b`).
extension AdvertAliases {
    /// The keys of one contact (``ExpectedTagTable/ContactKey``).
    typealias ContactKey = ExpectedTagTable.ContactKey

    /// Where an answer came from.
    enum Source: Hashable {
        /// A clear advert.
        case clear
        /// A contact's expected tag.
        case key
        /// A proven link's claim.
        case claim
        /// A responder's view of a dialer's `t`.
        case hint
    }

    /// A node id from a source. For a claim or a hint, ``claimant`` is the link that made it: the wiring holds off a dial
    /// on this answer only while that very link is held. Not part of the answer: two answers naming the same id from the
    /// same source are equal (`Resolved`, `:176-184`).
    struct Answer: Hashable {
        let nodeId: NodeId
        let source: Source
        let claimant: L?

        init(nodeId: NodeId, source: Source) {
            self.init(nodeId: nodeId, source: source, claimant: nil)
        }

        init(nodeId: NodeId, source: Source, claimant: L?) {
            self.nodeId = nodeId
            self.source = source
            self.claimant = claimant
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.nodeId == rhs.nodeId && lhs.source == rhs.source
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(nodeId)
            hasher.combine(source)
        }
    }

    /// What a form names.
    enum Resolution: Hashable {
        /// An id, and where it came from.
        case resolved(Answer)
        /// No contact's expected tag, claim or hint names it.
        case unresolved
        /// Marked blinded, but the bytes lack the tag prefix.
        case malformed
        /// One of my own tags, current or previous (`Resolution.Own`, `:186-187`).
        case own

        /// `nodeId` from `source`.
        static func resolved(_ nodeId: NodeId, _ source: Source) -> Self {
            .resolved(Answer(nodeId: nodeId, source: source))
        }
    }

    /// How a handshake event went (`ClaimOutcome`, `:196-223`).
    enum ClaimOutcome: Hashable {
        /// Now the link's claim.
        case recorded
        /// An announced tag, held until it is first heard.
        case pending
        /// A responder's view of the dialer's `t`, held as a hint.
        case hinted
        /// A contact's expected tag already names the same id.
        case redundant
        /// A contact's expected tag names a different id: dropped.
        case contradicted
        /// Another id claims the tag: both voided.
        case contested
        /// Not a claim under the rules.
        case ignored
        /// The claim table is full of claims that outrank this one.
        case full
        /// A second `TAG_NEXT` from the link inside the window: nothing recorded.
        case rateLimited

        /// Whether it settles an announced entry, which then goes, rather than leaving it to try again.
        var settles: Bool { self != .full }
    }

    /// Counts and table sizes only, never a key or a tag (`Counters`, `:226-269`).
    struct Counters: Hashable {
        var resolvedByKey = 0
        var resolvedByClaim = 0
        var resolvedByHint = 0
        var unresolved = 0
        var malformed = 0
        var claimsRecorded = 0
        var claimsDropped = 0
        var claimsVoided = 0
        var claimsIgnored = 0
        var claimsRefusedFull = 0
        /// Ended-link claims evicted to make room.
        var claimsEvicted = 0
        /// Announced tags and voids evicted at their cap.
        var entriesEvicted = 0
        var tagNextRateLimited = 0
        /// Tag dials that proved another id than a claim or hint named.
        var proofMismatches = 0
        /// Tag dials that proved another id than a key resolved the tag to: a replayed tag.
        var keyProofMismatches = 0
        var tableSize = 0
        var tableBuilds = 0
        var tableSlotSteps = 0
        /// Tags computed for the table: one HMAC each. Nothing else here computes one.
        var tableHmacs = 0
        var tableContacts = 0
        var claims = 0
        var pending = 0
        var voided = 0
        /// Queued expiries, stale ones included.
        var deadlines = 0
        var hints = 0
        var heldLinks = 0
        var lastTagNext = 0
    }

    final class Claim {
        let link: L
        let nodeId: NodeId
        var expiresAt: Int64
        /// Recorded from a dial to this very tag that proved ``nodeId``.
        let dialProven: Bool

        init(link: L, nodeId: NodeId, expiresAt: Int64, dialProven: Bool) {
            self.link = link
            self.nodeId = nodeId
            self.expiresAt = expiresAt
            self.dialProven = dialProven
        }
    }

    /// A void, and whether it came from two of our own dials or from claimants we never proved.
    final class VoidMark {
        let expiresAt: Int64
        let dialProven: Bool
        let claimants: [Claim]

        init(expiresAt: Int64, dialProven: Bool, claimants: [Claim]) {
            self.expiresAt = expiresAt
            self.dialProven = dialProven
            self.claimants = claimants
        }
    }

    /// The claim tables a deadline can name.
    enum Table {
        case claims
        case pending
    }

    /// One entry's expiry; it removes the entry only if that is still the one it was queued for, and still due.
    enum Lapse {
        case claim(Table, NodeId, Claim)
        case void(NodeId, VoidMark)
    }
}
