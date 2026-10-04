import KnitSync
public import KnitWire

/// The people the user blocked (`SettingsStore.blockedNodeIds` and `blockedDeviceTags` in knit-next). A block is
/// presentation only: the delivery path reads it, and custody, relaying and key exchange never do (ADR 2026-10.5wgg).
///
/// A block keeps two things: the node id, and the device tag that person's profile carried, so the block follows
/// them when they make new keys (`DeviceTag`).
public protocol BlockStore: AnyObject, Sendable {
    /// Everyone blocked.
    func blockedNodeIds() -> Set<NodeId>

    /// Whether `deviceTag` belongs to someone blocked. Tags arrive in peers' profiles, so they compare by their bytes
    /// (ADR 2026-09.jc2x).
    func isBlocked(deviceTag: String) -> Bool

    /// Blocks `nodeId`, and `deviceTag` with it when there is one.
    func block(_ nodeId: NodeId, deviceTag: String?)

    /// Unblocks `nodeId`, and `deviceTag` with it when there is one. Anyone else blocked through the same tag stays
    /// blocked, as on Android (`SettingsStore.unblock`).
    func unblock(_ nodeId: NodeId, deviceTag: String?)
}

/// A ``BlockStore`` in memory.
public final class MemoryBlockStore: BlockStore {
    private struct State {
        var nodeIds: Set<NodeId> = []
        var deviceTags: Set<ExactKey> = []
    }

    private let state = Lock(State())

    /// An empty store.
    public init() {
        // Nothing to set up.
    }

    public func blockedNodeIds() -> Set<NodeId> {
        state.withLock { $0.nodeIds }
    }

    public func isBlocked(deviceTag: String) -> Bool {
        state.withLock { $0.deviceTags.contains(ExactKey(deviceTag)) }
    }

    public func block(_ nodeId: NodeId, deviceTag: String?) {
        state.withLock { state in
            state.nodeIds.insert(nodeId)
            if let deviceTag {
                state.deviceTags.insert(ExactKey(deviceTag))
            }
        }
    }

    public func unblock(_ nodeId: NodeId, deviceTag: String?) {
        state.withLock { state in
            state.nodeIds.remove(nodeId)
            if let deviceTag {
                state.deviceTags.remove(ExactKey(deviceTag))
            }
        }
    }
}
