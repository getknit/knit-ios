import KnitStore
import KnitSync
import KnitWire

/// A ratchet store whose writes can be refused, as a full disk refuses them: told to, every write fails the store unit
/// it runs in and changes nothing, and every read goes to the store it wraps. `refuse` is how the unit fails, as
/// ``RefusingMessageStore``'s is: a memory unit is told so, and the database is handed a write SQLite refuses
/// (``StoreKind``). Every ratchet open writes its delta here before what it carries, so a refused write fails the unit
/// of any frame, a ctl frame's included.
final class RefusingRatchetWrites: RatchetStore {
    let held: any RatchetStore
    private let refuse: @Sendable () -> Void
    private let refusing = Lock(false)

    init(_ held: any RatchetStore, refuse: @escaping @Sendable () -> Void) {
        self.held = held
        self.refuse = refuse
    }

    /// Whether a write is refused now.
    var refusesWrites: Bool {
        get { refusing.withLock { $0 } }
        set { refusing.withLock { $0 = newValue } }
    }

    private func write(_ change: () -> Void) {
        guard refusesWrites else {
            change()
            return
        }
        refuse()
    }

    func session(_ peer: NodeId) -> RatchetSessionRecord? { held.session(peer) }
    func sessionPeerIds() -> [NodeId] { held.sessionPeerIds() }
    func localEpochPrivateKey(_ peer: NodeId, epoch: Int) -> [UInt8]? { held.localEpochPrivateKey(peer, epoch: epoch) }
    func lowestLocalEpoch(_ peer: NodeId) -> Int? { held.lowestLocalEpoch(peer) }
    func recvEpochs(_ peer: NodeId, epoch: Int) -> [RatchetRecvEpochRecord] { held.recvEpochs(peer, epoch: epoch) }
    func skippedKeys(_ peer: NodeId, epoch: Int, index: Int) -> [RatchetSkippedKeyRecord] {
        held.skippedKeys(peer, epoch: epoch, index: index)
    }
    func records(of peer: NodeId) -> RatchetPeerRecords { held.records(of: peer) }

    func upsertSession(_ session: RatchetSessionRecord) {
        write { held.upsertSession(session) }
    }

    func applyOpen(_ delta: RatchetOpenDelta, from peer: NodeId, se: Int, n: Int) {
        write { held.applyOpen(delta, from: peer, se: se, n: n) }
    }

    func commitSend(_ session: RatchetSessionRecord, newLocalEpoch: RatchetLocalEpochRecord?) {
        write { held.commitSend(session, newLocalEpoch: newLocalEpoch) }
    }

    func purgeReceiveState(_ peer: NodeId) {
        write { held.purgeReceiveState(peer) }
    }

    func deletePeer(_ peer: NodeId) {
        write { held.deletePeer(peer) }
    }

    func sweep(now: Int64) {
        write { held.sweep(now: now) }
    }
}
