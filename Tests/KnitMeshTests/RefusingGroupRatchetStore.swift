import KnitStore
import KnitSync
import KnitWire

/// A group-ratchet store in memory that fails as a database can, as ``RefusingRatchetStore`` does for the DM side: a read
/// or a write it is told to refuse answers its fallback and fails the store unit it runs in, and outside a unit fails
/// nothing (ADR 2026-10.5sk9's P4a amendment). Its ``transactor`` covers the store it wraps.
final class RefusingGroupRatchetStore: GroupRatchetStore {
    let held = MemoryGroupRatchetStore()
    let transactor: MemoryTransactor
    private let refusing = Lock(RefusingRatchetStore.Refusals())

    init() {
        transactor = MemoryTransactor(stores: [held])
    }

    /// Refuses `refusals` from now on, until told otherwise.
    func refuse(_ refusals: RefusingRatchetStore.Refusals) {
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

    func sendChain(_ group: String) -> GroupSendChainRecord? {
        read(nil) { held.sendChain(group) }
    }

    func sendChains(_ group: String) -> [GroupSendChainRecord] {
        read([]) { held.sendChains(group) }
    }

    func commitSend(_ chain: GroupSendChainRecord, in group: String) {
        write { held.commitSend(chain, in: group) }
    }

    func retireSendChains(_ group: String) {
        write { held.retireSendChains(group) }
    }

    func recvChains(_ group: String, from sender: NodeId, epoch: Int) -> [GroupRecvChainRecord] {
        read([]) { held.recvChains(group, from: sender, epoch: epoch) }
    }

    func skippedKeys(_ group: String, from sender: NodeId, epoch: Int, index: Int) -> [GroupSkippedKeyRecord] {
        read([]) { held.skippedKeys(group, from: sender, epoch: epoch, index: index) }
    }

    func insertRecvChain(_ chain: GroupRecvChainRecord, in group: String, from sender: NodeId) {
        write { held.insertRecvChain(chain, in: group, from: sender) }
    }

    func applyOpen(_ delta: GroupOpenDelta, in group: String, from sender: NodeId, se: Int, n: Int) {
        write { held.applyOpen(delta, in: group, from: sender, se: se, n: n) }
    }

    func purgeGroup(_ group: String) {
        write { held.purgeGroup(group) }
    }

    func keySend(_ group: String, member: NodeId) -> GroupKeySendRecord? {
        read(nil) { held.keySend(group, member: member) }
    }

    func keySends(_ group: String) -> [GroupKeySendRecord] {
        read([]) { held.keySends(group) }
    }

    func markKeySent(_ group: String, to member: NodeId, epoch: Int, at: Int64) {
        write { held.markKeySent(group, to: member, epoch: epoch, at: at) }
    }

    func markKeyAcked(_ group: String, by member: NodeId, epoch: Int, at: Int64) {
        write { held.markKeyAcked(group, by: member, epoch: epoch, at: at) }
    }

    func deleteKeySend(_ group: String, member: NodeId) {
        write { held.deleteKeySend(group, member: member) }
    }

    func holdings(of group: String) -> GroupRatchetHoldings {
        read(.empty) { held.holdings(of: group) }
    }

    func sweep(now: Int64) {
        write { held.sweep(now: now) }
    }
}
