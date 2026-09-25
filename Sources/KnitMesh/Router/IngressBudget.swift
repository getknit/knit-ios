public import KnitWire

/// A token bucket per link over the one frame anyone in range can write, the cleartext room post
/// (`IngressBudget.kt`).
///
/// Every other bound on a room post is keyed on a node id, and a node id costs nothing to mint, so a flood can
/// wear a fresh identity per frame. A link is one radio peer, so metering the link a frame arrived over gives
/// an attacking device one link's budget however many identities it claims. A refused post is not marked
/// seen: custody serves it again later, so a burst over budget is delayed, never lost.
public struct IngressBudget<Link: Hashable & Sendable>: Sendable {
    /// Room posts one link may hand over at once: a full custody re-serve of the room quota, plus headroom.
    public static var defaultBurst: Int { IngressDefaults.burst }
    /// Room posts per minute one link may sustain.
    public static var defaultPerMinute: Int { IngressDefaults.perMinute }

    private struct Bucket: Sendable {
        var tokens: Double
        var refilledAt: Int64
    }

    private let burst: Double
    private let perMinute: Double
    private var buckets: [Link: Bucket] = [:]
    /// Links from least to most recently used. An evicted link comes back with a full bucket, the same gain as
    /// linking again, which the radio already charges seconds for.
    private var recency: [Link] = []

    /// A budget with knit-next's sizes unless told otherwise.
    public init(burst: Int = Self.defaultBurst, perMinute: Int = Self.defaultPerMinute) {
        self.burst = Double(burst)
        self.perMinute = Double(perMinute)
    }

    /// Whether `envelope` is metered: a room post, which is a chat with no recipient and no group.
    public static func meters(_ envelope: RelayEnvelope) -> Bool {
        envelope.type == .chat && envelope.recipientId == nil && envelope.group == nil
    }

    /// Takes one token from `link`'s bucket, or answers `false` when it is empty and the frame is refused.
    public mutating func admit(link: Link, now: Int64) -> Bool {
        var bucket = buckets[link] ?? Bucket(tokens: burst, refilledAt: now)
        let elapsed = Double(max(0, now - bucket.refilledAt))
        bucket.tokens = min(burst, bucket.tokens + elapsed * perMinute / IngressDefaults.millisecondsPerMinute)
        bucket.refilledAt = now
        let admitted = bucket.tokens >= 1
        if admitted {
            bucket.tokens -= 1
        }
        buckets[link] = bucket
        touch(link)
        return admitted
    }

    private mutating func touch(_ link: Link) {
        recency.removeAll { $0 == link }
        recency.append(link)
        if recency.count > IngressDefaults.maxLinks {
            buckets[recency.removeFirst()] = nil
        }
    }
}

/// knit-next's sizes. A generic type cannot hold stored statics, so they live here.
private enum IngressDefaults {
    static let burst = 240
    static let perMinute = 30
    /// Links remembered; the least recently used is forgotten past this.
    static let maxLinks = 64
    static let millisecondsPerMinute: Double = 60_000
}
