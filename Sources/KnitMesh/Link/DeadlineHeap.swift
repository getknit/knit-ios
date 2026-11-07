/// A binary heap has two children per node.
private let heapArity = 2

/// A binary min-heap of deadlines (Kotlin's `PriorityQueue`), so expiry never walks the tables.
internal struct DeadlineHeap<Value> {
    private var items: [(at: Int64, value: Value)] = []

    /// Deadlines queued, stale ones included.
    var count: Int { items.count }

    /// Queues `value` at `at`.
    mutating func push(_ value: Value, at: Int64) {
        items.append((at, value))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / heapArity
            guard items[child].at < items[parent].at else {
                break
            }
            items.swapAt(child, parent)
            child = parent
        }
    }

    /// Takes the earliest deadline at or before `now`, if one is due.
    mutating func popDue(_ now: Int64) -> Value? {
        guard let first = items.first, first.at <= now else {
            return nil
        }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var parent = 0
            while true {
                let left = heapArity * parent + 1
                let right = left + 1
                var smallest = parent
                if left < items.count, items[left].at < items[smallest].at {
                    smallest = left
                }
                if right < items.count, items[right].at < items[smallest].at {
                    smallest = right
                }
                guard smallest != parent else {
                    break
                }
                items.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return first.value
    }

    /// Drops every deadline.
    mutating func removeAll() {
        items.removeAll()
    }
}
