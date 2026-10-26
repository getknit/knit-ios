/// Which frames have already crossed which link, in either direction, so a frame goes down one link at most
/// once (`LinkCrossings.kt`).
///
/// The window is the receiver's `SeenSet` window, and frames are marked on the way in as well as out, so
/// anything skipped is a frame the far end would drop anyway. It is forgotten with the link: a new link to the
/// same peer starts clean, because the peer may have restarted with an empty store.
///
/// Kotlin keeps one memo per link for both directions. This port keeps two, what we wrote and what the link gave
/// us, each with Kotlin's size and window, because every decodable inbound frame is stamped before the router or
/// a signature has looked at it: a neighbour sending 1,025 junk frames with fresh ids would otherwise evict every
/// outbound stamp, and with them the bound of one write per frame per link per window that custody re-serves lean
/// on. An inbound stamp now evicts only an inbound one (ADR 2026-10.f5zs).
public struct LinkCrossings<Link: Hashable & Sendable>: Sendable {
    /// Per link and direction: above the custody cap plus a busy room's minute.
    public static var defaultMaxPerLink: Int { crossingsPerLink }

    private let maxPerLink: Int
    private let window: Int64
    /// What we wrote to each link.
    private var written: [Link: SeenSet] = [:]
    /// What each link gave us.
    private var given: [Link: SeenSet] = [:]

    /// Crossings with knit-next's sizes unless told otherwise.
    public init(maxPerLink: Int = Self.defaultMaxPerLink, windowMilliseconds: Int64 = SeenSet.defaultWindowMilliseconds) {
        self.maxPerLink = maxPerLink
        window = windowMilliseconds
    }

    /// The frame keys held, over every link and both directions: the footprint's `crossings`.
    public var count: Int {
        written.values.reduce(0) { $0 + $1.count } + given.values.reduce(0) { $0 + $1.count }
    }

    /// Asks to write the frame with `key` to `link` now. `true` the first time inside the window, and the write is
    /// recorded: write it. `false` when the link gave us the frame or we already wrote it: skip it, the far end has
    /// it.
    public mutating func firstCrossing(link: Link, key: String, now: Int64) -> Bool {
        if given[link]?.contains(key, now: now) == true {
            return false
        }
        let fresh = memo()
        return written[link, default: fresh].insert(key, now: now)
    }

    /// Records that `link` gave us the frame with `key` now, so nothing written to it later is that frame. Bounded
    /// apart from the writes, so whatever a neighbour sends cannot evict them (ADR 2026-10.f5zs).
    public mutating func arrived(link: Link, key: String, now: Int64) {
        let fresh = memo()
        _ = given[link, default: fresh].insert(key, now: now)
    }

    /// Whether the frame with `key` crossed `link` either way inside the window. Records nothing, so a reply round
    /// can leave out what the link already has without spending a write.
    public func hasCrossed(link: Link, key: String, now: Int64) -> Bool {
        given[link]?.contains(key, now: now) == true || written[link]?.contains(key, now: now) == true
    }

    /// The link went down, or came up anew: whatever crossed it, either way, no longer counts.
    public mutating func forget(link: Link) {
        written[link] = nil
        given[link] = nil
    }

    private func memo() -> SeenSet {
        SeenSet(capacity: maxPerLink, windowMilliseconds: window)
    }
}

/// knit-next's `MAX_PER_LINK`. A generic type cannot hold stored statics, so it lives here.
private let crossingsPerLink = 1024
