import KnitWire

/// ``KeyExchange``'s hot layer over the pin store: the signed profiles it serves, at most ``capacity`` of them, the least
/// recently used dropped first. Every entry is a pin, and pins cost no more than a profile frame, so without a bound the
/// cache would grow with every sender ever pinned since launch. A dropped entry is not lost: the pin store keeps the frame
/// each pin came from, and the next miss reads it back, as one after a restart does. Android's cache has no bound
/// (`KeyExchange.kt:70` at knit-next `e63f15f4`); nothing a peer sees depends on which entries are cached here, only how
/// often the pin store is read.
///
/// The order is a doubly linked list threaded through the dictionary by node id, so a lookup, a touch, an insert and an
/// eviction each cost O(1), and which entry goes first is a function of the calls alone, never of a hash seed.
internal struct ProfileCache: Sendable {
    /// The most profiles held: past it, the least recently used is dropped.
    let capacity: Int

    private struct Node: Sendable {
        var profile: WireEnvelope
        /// The next more recently used entry, `nil` for the newest.
        var newer: NodeId?
        /// The next less recently used entry, `nil` for the oldest.
        var older: NodeId?
    }

    private var nodes: [NodeId: Node] = [:]
    private var newest: NodeId?
    private var oldest: NodeId?

    /// An empty cache of at most `capacity` profiles, at least one.
    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// The profiles held.
    var count: Int { nodes.count }

    /// The profile held for `nodeId`, leaving the order as it is: what a read that serves nothing sees.
    func peek(_ nodeId: NodeId) -> WireEnvelope? {
        nodes[nodeId]?.profile
    }

    /// Whether a profile is held for `nodeId`, leaving the order as it is.
    func contains(_ nodeId: NodeId) -> Bool {
        nodes[nodeId] != nil
    }

    /// The profile held for `nodeId`, made the most recently used.
    mutating func use(_ nodeId: NodeId) -> WireEnvelope? {
        guard let node = nodes[nodeId] else {
            return nil
        }
        moveToNewest(nodeId)
        return node.profile
    }

    /// Holds `profile` for `nodeId` as the most recently used, replacing what was held, and drops the least recently used
    /// past ``capacity``.
    mutating func set(_ profile: WireEnvelope, for nodeId: NodeId) {
        if nodes[nodeId] != nil {
            nodes[nodeId]?.profile = profile
            moveToNewest(nodeId)
            return
        }
        nodes[nodeId] = Node(profile: profile, newer: nil, older: newest)
        if let previous = newest {
            nodes[previous]?.newer = nodeId
        } else {
            oldest = nodeId
        }
        newest = nodeId
        // One entry goes in at a time, so one past the capacity, at least one, leaves two or more: the oldest has a newer.
        if nodes.count > capacity, let victim = oldest {
            oldest = nodes[victim]?.newer
            nodes[victim] = nil
            if let next = oldest {
                nodes[next]?.older = nil
            }
        }
    }

    /// Moves the held `nodeId` to the newest end. Unless it is the newest already, a newer entry follows it, so only its
    /// older side can be the end of the list.
    private mutating func moveToNewest(_ nodeId: NodeId) {
        guard newest != nodeId, let previous = newest else {
            return
        }
        let older = nodes[nodeId]?.older
        let newer = nodes[nodeId]?.newer
        if let older {
            nodes[older]?.newer = newer
        } else {
            oldest = newer
        }
        if let newer {
            nodes[newer]?.older = older
        }
        nodes[nodeId]?.older = previous
        nodes[nodeId]?.newer = nil
        nodes[previous]?.newer = nodeId
        newest = nodeId
    }
}
