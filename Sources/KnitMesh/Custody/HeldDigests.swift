public import KnitWire

/// The digests whose reply round waits on its link (ADR 2026-10.f5zs): the round waits on the link, never on the peer.
///
/// A reply round queues up to ``CustodySync/roundBytes`` on a link. While the link still holds ``lineBytes``, half a
/// round, unwritten (`MeshTransport.queuedBytes(to:)`), another round would only stack behind the last one, so a peer
/// that reads slowly, or not at all, would be handed a round per digest. Holding at half a round keeps a slow link at
/// about one round queued, where a line at a whole round let it reach two. The digest waits here instead, one slot per neighbour: a newer
/// one takes the held one's place, since it says more truly what the peer lacks, and the link going clears it. Every
/// ``recheckMilliseconds`` the engine takes the held digests and answers each whose link fell below the line, holding
/// again any that did not. A file feed keeps at most its window queued, below the line, so a photo streaming never holds
/// a round off.
///
/// Android has no hold: it serves every digest whole into an unbounded writer (`ForwardSync.kt:136-163` at knit-next
/// `e63f15f4`). The hold changes only when we answer, never what, so it is this port's alone.
public struct HeldDigests: Sendable {
    /// The unwritten bytes at which a link's round waits: half a round still queued, 128 KiB. A file feed's window is at
    /// most 64 KiB (`FeedWindow.maxWindowBytes`), so a photo streaming stays under it.
    public static let lineBytes = CustodySync.roundBytes / roundsPerLine

    /// Half a round: ``lineBytes`` is the round's bytes over this.
    private static let roundsPerLine = 2
    /// How often the held digests are looked at again, on the monotonic clock.
    public static let recheckMilliseconds: Int64 = 5000

    /// A digest whose round waits.
    public struct Held: Sendable, Equatable {
        /// The neighbour that sent it.
        public var neighbor: NodeId
        /// The ids it listed.
        public var ids: [String]

        /// A held digest.
        public init(neighbor: NodeId, ids: [String]) {
            self.neighbor = neighbor
            self.ids = ids
        }
    }

    /// One per neighbour, in the order they were first held. Neighbours are bounded by the links.
    private var held: [Held] = []

    /// When the held digests are next looked at, or `nil` when none waits: an engine deadline (ADR 2026-09.gq84).
    public private(set) var nextCheck: Int64?

    /// No digest held.
    public init() {
        // Nothing held.
    }

    /// The digests held now, oldest neighbour first.
    public var digests: [Held] { held }

    /// Holds `ids` from `neighbor` in place of any digest of theirs held already, and answers whether none was. The next
    /// look stays where it was, so a peer that sends digests often cannot put it off.
    @discardableResult
    public mutating func hold(_ ids: [String], from neighbor: NodeId, now: Int64) -> Bool {
        nextCheck = nextCheck ?? now + Self.recheckMilliseconds
        if let index = held.firstIndex(where: { $0.neighbor == neighbor }) {
            held[index].ids = ids
            return false
        }
        held.append(Held(neighbor: neighbor, ids: ids))
        return true
    }

    /// Forgets `neighbor`'s digest: its link went, and the next link's digest says what it lacks then.
    public mutating func drop(_ neighbor: NodeId) {
        held.removeAll { $0.neighbor == neighbor }
        if held.isEmpty {
            nextCheck = nil
        }
    }

    /// Every held digest, if the look is due, and nothing held after: the caller answers each one or holds it again.
    public mutating func takeDue(now: Int64) -> [Held] {
        guard let nextCheck, now >= nextCheck else {
            return []
        }
        defer {
            held.removeAll()
            self.nextCheck = nil
        }
        return held
    }
}
