/// Which frames have already crossed which link, in either direction, so a frame goes down one link at most
/// once (`LinkCrossings.kt`).
///
/// The window is the receiver's `SeenSet` window, and frames are marked on the way in as well as out, so
/// anything skipped is a frame the far end would drop anyway. It is forgotten with the link: a new link to the
/// same peer starts clean, because the peer may have restarted with an empty store.
public struct LinkCrossings<Link: Hashable & Sendable>: Sendable {
    /// Per link: above the custody cap plus a busy room's minute.
    public static var defaultMaxPerLink: Int { crossingsPerLink }

    private let maxPerLink: Int
    private let window: Int64
    private var perLink: [Link: SeenSet] = [:]

    /// Crossings with knit-next's sizes unless told otherwise.
    public init(maxPerLink: Int = Self.defaultMaxPerLink, windowMilliseconds: Int64 = SeenSet.defaultWindowMilliseconds) {
        self.maxPerLink = maxPerLink
        window = windowMilliseconds
    }

    /// The frame ids held, over every link.
    public var count: Int { perLink.values.reduce(0) { $0 + $1.count } }

    /// Records that the frame with `key` crosses `link` now. `true` the first time inside the window: write it.
    /// `false` for a repeat: skip it, the far end has it.
    public mutating func firstCrossing(link: Link, key: String, now: Int64) -> Bool {
        perLink[link, default: SeenSet(capacity: maxPerLink, windowMilliseconds: window)].insert(key, now: now)
    }

    /// The link went down, or came up anew: whatever crossed it no longer counts.
    public mutating func forget(link: Link) {
        perLink[link] = nil
    }
}

/// knit-next's `MAX_PER_LINK`. A generic type cannot hold stored statics, so it lives here.
private let crossingsPerLink = 1024
