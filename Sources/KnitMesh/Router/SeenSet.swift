/// The frame ids this node has already handled, which is what ends a flood (`SeenSet.kt`).
///
/// An id is new again once its window has passed, and the set keeps at most `capacity` ids, dropping the
/// oldest-inserted first. Callers pass the time, in milliseconds on the monotonic clock, so the lab can drive
/// it.
public struct SeenSet: Sendable {
    /// An id counts as new again after 10 minutes.
    public static let defaultWindowMilliseconds: Int64 = 600_000
    /// The ids kept.
    public static let defaultCapacity = 4096
    /// Reopened ids are remembered so they cannot be reopened twice.
    private static let reopenedCapacity = 256

    private let window: Int64
    private var seen: StampedKeys
    private var reopened = StampedKeys(capacity: Self.reopenedCapacity)

    /// A set with knit-next's capacity and window unless told otherwise.
    public init(capacity: Int = Self.defaultCapacity, windowMilliseconds: Int64 = Self.defaultWindowMilliseconds) {
        window = windowMilliseconds
        seen = StampedKeys(capacity: capacity)
    }

    /// The ids held. One whose window has passed stays until capacity evicts it, so this reaches `capacity` and
    /// stays there.
    public var count: Int { seen.count }

    /// Records `id` and answers whether it is new: never seen, or last seen a full window ago.
    public mutating func insert(_ id: String, now: Int64) -> Bool {
        if let last = seen[id], now - last < window {
            return false
        }
        seen.stamp(id, at: now)
        return true
    }

    /// Whether `id` was seen inside the window.
    public func contains(_ id: String, now: Int64) -> Bool {
        guard let last = seen[id] else {
            return false
        }
        return now - last < window
    }

    /// Lets one more copy of `id` through inside its window, for a sealed DM this node took but could not open
    /// because it no longer holds the session. The sender's answer to our reset is a fresh seal under the same id
    /// (no wire change, and the exists-gate dedups it), which can land seconds after the copy custody just served
    /// us, so without this it would be dropped as a repeat. Only we reopen: a relay that saw the id in its window
    /// drops that seal too, so the sender seals it once more after the window (knit-next `SeenSet.kt:38-47` at
    /// `4f3cd995`, ADR 2026-10.dmgw). Once per id per window, so a peer re-serving an unopenable frame buys at
    /// most one extra relay. Answers whether the id was reopened.
    public mutating func reopen(_ id: String, now: Int64) -> Bool {
        guard let last = seen[id], now - last < window else {
            return false
        }
        if let reopenedAt = reopened[id], now - reopenedAt < window {
            return false
        }
        seen.remove(id)
        reopened.stamp(id, at: now)
        return true
    }
}
