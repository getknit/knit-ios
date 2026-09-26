import KnitWire

/// Keys with a millisecond stamp each, evicted oldest-inserted first once there are more than `capacity`.
///
/// This is Kotlin's insertion-ordered `LinkedHashMap` with `removeEldestEntry`, which knit-next's `SeenSet` is
/// built on. Restamping a key keeps its place in line; removing it and inserting it again sends it to the back.
/// Removed keys leave stale entries in the queue, which eviction skips and compaction drops. Keys compare by
/// their bytes, as Kotlin's do (``ExactKey``).
internal struct StampedKeys: Sendable {
    /// Consumed queue entries are dropped once they are more than half the queue.
    private static let compactionDivisor = 2

    private struct Entry: Sendable {
        var stamp: Int64
        var sequence: Int
    }

    private let capacity: Int
    private var entries: [ExactKey: Entry] = [:]
    private var queue: [(key: ExactKey, sequence: Int)] = []
    private var head = 0
    private var nextSequence = 0

    init(capacity: Int) {
        // A set that holds nothing would evict every key as it arrived.
        self.capacity = max(1, capacity)
    }

    /// The keys held, stale ones included until they are evicted.
    var count: Int { entries.count }

    /// The key's stamp, or `nil` when the key is not held.
    subscript(key: String) -> Int64? { entries[ExactKey(key)]?.stamp }

    /// Stamps `key`, appending it when it is new and evicting the oldest-inserted key past `capacity`.
    mutating func stamp(_ text: String, at stamp: Int64) {
        let key = ExactKey(text)
        if entries[key] != nil {
            entries[key]?.stamp = stamp
            return
        }
        entries[key] = Entry(stamp: stamp, sequence: nextSequence)
        queue.append((key, nextSequence))
        nextSequence += 1
        while entries.count > capacity {
            evictOldest()
        }
    }

    /// Drops `key`, if it is held.
    mutating func remove(_ key: String) {
        entries[ExactKey(key)] = nil
    }

    private mutating func evictOldest() {
        while head < queue.count {
            let (key, sequence) = queue[head]
            head += 1
            if entries[key]?.sequence == sequence {
                entries[key] = nil
                break
            }
        }
        if head > queue.count / Self.compactionDivisor {
            queue.removeFirst(head)
            head = 0
        }
    }
}
