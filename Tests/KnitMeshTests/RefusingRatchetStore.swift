import KnitStore
import KnitSync
import KnitWire

/// A ratchet store in memory that fails as a database can: a read or a write it is told to refuse answers its fallback
/// and fails the store unit it runs in, as ``KnitDatabase``'s error does, and outside a unit fails nothing (ADR
/// 2026-10.5sk9's P4a amendment). Its ``transactor`` covers the store it wraps.
final class RefusingRatchetStore: RatchetStore {
    /// What it refuses.
    struct Refusals: OptionSet, Sendable {
        let rawValue: Int
        /// Every read.
        static let reads = Self(rawValue: 1)
        /// Every write.
        static let writes = Self(rawValue: 2)
    }

    let held = MemoryRatchetStore()
    let transactor: MemoryTransactor
    private let refusing = Lock(Refusals())

    init() {
        transactor = MemoryTransactor(stores: [held])
    }

    /// Refuses `refusals` from now on, until told otherwise.
    func refuse(_ refusals: Refusals) {
        refusing.withLock { $0 = refusals }
    }

    private func read<Value>(_ fallback: Value, _ value: () -> Value) -> Value {
        guard refusing.withLock({ $0.contains(.reads) }) else {
            return value()
        }
        transactor.failCurrentUnit()
        return fallback
    }

    private func write(_ change: () -> Void) {
        guard refusing.withLock({ $0.contains(.writes) }) else {
            change()
            return
        }
        transactor.failCurrentUnit()
    }

    func session(_ peer: NodeId) -> RatchetSessionRecord? {
        read(nil) { held.session(peer) }
    }

    func upsertSession(_ session: RatchetSessionRecord) {
        write { held.upsertSession(session) }
    }

    func localEpochPrivateKey(_ peer: NodeId, epoch: Int) -> [UInt8]? {
        read(nil) { held.localEpochPrivateKey(peer, epoch: epoch) }
    }

    func recvEpochs(_ peer: NodeId, epoch: Int) -> [RatchetRecvEpochRecord] {
        read([]) { held.recvEpochs(peer, epoch: epoch) }
    }

    func skippedKeys(_ peer: NodeId, epoch: Int, index: Int) -> [RatchetSkippedKeyRecord] {
        read([]) { held.skippedKeys(peer, epoch: epoch, index: index) }
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

    func records(of peer: NodeId) -> RatchetPeerRecords {
        held.records(of: peer)
    }

    func sweep(now: Int64) {
        write { held.sweep(now: now) }
    }
}
