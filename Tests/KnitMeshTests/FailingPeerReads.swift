import KnitMesh
import KnitStore
import KnitSync
import KnitWire

/// A peer store whose row reads fail when told to, as a database that cannot read its file fails them: the next
/// ``failsReads`` calls to ``peer(_:)`` answer `nil`, the fallback `SQLPeerStore.peer` answers outside a store unit
/// (`database.read(or: nil)`, ADR 2026-09.nyya), and everything else goes to the store it wraps. The engine reads a peer's
/// row outside any unit, so no unit is failed.
final class FailingPeerReads: PeerStore {
    let held: any PeerStore
    private let failing = Lock(0)

    init(_ held: any PeerStore) {
        self.held = held
    }

    /// How many of the next row reads fail.
    var failsReads: Int {
        get { failing.withLock { $0 } }
        set { failing.withLock { $0 = newValue } }
    }

    func peer(_ nodeId: NodeId) -> PeerRecord? {
        let fails = failing.withLock { count -> Bool in
            guard count > 0 else {
                return false
            }
            count -= 1
            return true
        }
        return fails ? nil : held.peer(nodeId)
    }

    func upsert(_ peer: PeerRecord) { held.upsert(peer) }
    func verifiedNodeIds() -> Set<NodeId> { held.verifiedNodeIds() }
    func allPeers() -> [PeerRecord] { held.allPeers() }
    func recordProfileFrame(_ frame: WireEnvelope, of nodeId: NodeId, sentAt: Int64) {
        held.recordProfileFrame(frame, of: nodeId, sentAt: sentAt)
    }
    func profileFrame(of nodeId: NodeId) -> WireEnvelope? { held.profileFrame(of: nodeId) }
}

extension MeshStores {
    /// These stores with the peers' swapped for `peers`, a wrapper over the store the transactor was made over, so a unit
    /// that is undone still puts it back.
    func replacing(peers: any PeerStore) -> Self {
        MeshStores(
            custody: custody,
            peers: peers,
            messages: messages,
            conversations: conversations,
            blocks: blocks,
            groups: groups,
            ownProfile: ownProfile,
            blobs: blobs,
            ratchet: ratchet,
            groupRatchet: groupRatchet,
            transactor: transactor
        )
    }
}
