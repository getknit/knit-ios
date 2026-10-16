import KnitStore
import KnitSync
import KnitWire

/// A peer store whose row read can fail, as a database that cannot read its file fails it: told to, ``peer(_:)`` fails the
/// store unit it runs in and answers `nil`, the store's fallback, and everything else goes to the store it wraps. `refuse`
/// is how the unit fails, as ``RefusingMessageStore``'s is (``StoreKind``). Outside a unit only the fallback is left, so a
/// caller reading there cannot tell the failure from a peer never pinned, which is why a sealed receipt reads its author's
/// row inside its unit (ADR 2026-10.5sk9's P5d amendment).
final class RefusingPeerReads: PeerStore {
    let held: any PeerStore
    private let refuse: @Sendable () -> Void
    private let failing = Lock(false)

    init(_ held: any PeerStore, refuse: @escaping @Sendable () -> Void) {
        self.held = held
        self.refuse = refuse
    }

    /// Whether a row read fails now.
    var failsReads: Bool {
        get { failing.withLock { $0 } }
        set { failing.withLock { $0 = newValue } }
    }

    func peer(_ nodeId: NodeId) -> PeerRecord? {
        guard failsReads else {
            return held.peer(nodeId)
        }
        refuse()
        return nil
    }

    func upsert(_ peer: PeerRecord) { held.upsert(peer) }
    func verifiedNodeIds() -> Set<NodeId> { held.verifiedNodeIds() }
    func allPeers() -> [PeerRecord] { held.allPeers() }
    func recordProfileFrame(_ frame: WireEnvelope, of nodeId: NodeId, sentAt: Int64) {
        held.recordProfileFrame(frame, of: nodeId, sentAt: sentAt)
    }
    func profileFrame(of nodeId: NodeId) -> WireEnvelope? { held.profileFrame(of: nodeId) }
}
