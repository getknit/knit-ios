import Foundation
import KnitStore
import KnitStoreSQL
import KnitSync
import KnitWire

@testable import KnitMesh

/// A group-ratchet store whose writes can be refused, as a full disk refuses them, inside the engine's own store unit, as
/// ``RefusingRatchetWrites`` is for the DM side: told to, every write fails the unit it runs in and changes nothing, and
/// every read goes to the store it wraps. `refuse` is how the unit fails (``StoreKind``). The roster's units and the group
/// send's unit each write here (phase P6b), so a refused write fails them whole.
final class RefusingGroupRatchetWrites: GroupRatchetStore {
    let held: any GroupRatchetStore
    private let refuse: @Sendable () -> Void
    private let refusing = Lock(false)

    init(_ held: any GroupRatchetStore, refuse: @escaping @Sendable () -> Void) {
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

    func sendChain(_ group: String) -> GroupSendChainRecord? { held.sendChain(group) }
    func sendChains(_ group: String) -> [GroupSendChainRecord] { held.sendChains(group) }
    func recvChains(_ group: String, from sender: NodeId, epoch: Int) -> [GroupRecvChainRecord] {
        held.recvChains(group, from: sender, epoch: epoch)
    }
    func skippedKeys(_ group: String, from sender: NodeId, epoch: Int, index: Int) -> [GroupSkippedKeyRecord] {
        held.skippedKeys(group, from: sender, epoch: epoch, index: index)
    }
    func keySend(_ group: String, member: NodeId) -> GroupKeySendRecord? { held.keySend(group, member: member) }
    func keySends(_ group: String) -> [GroupKeySendRecord] { held.keySends(group) }
    func holdings(of group: String) -> GroupRatchetHoldings { held.holdings(of: group) }

    func commitSend(_ chain: GroupSendChainRecord, in group: String) {
        write { held.commitSend(chain, in: group) }
    }

    func retireSendChains(_ group: String) {
        write { held.retireSendChains(group) }
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

    func markKeySent(_ group: String, to member: NodeId, epoch: Int, at: Int64) {
        write { held.markKeySent(group, to: member, epoch: epoch, at: at) }
    }

    func markKeyAcked(_ group: String, by member: NodeId, epoch: Int, at: Int64) {
        write { held.markKeyAcked(group, by: member, epoch: epoch, at: at) }
    }

    func deleteKeySend(_ group: String, member: NodeId) {
        write { held.deleteKeySend(group, member: member) }
    }

    func sweep(now: Int64) {
        write { held.sweep(now: now) }
    }
}

extension StoreKind {
    /// Stores of this kind whose group-ratchet store refuses its writes when told to, and the refusing store: every unit that
    /// writes the group form's state fails then.
    func storesRefusingGroupWrites(blobs: URL, failures: @escaping @Sendable (any Error) -> Void) throws -> (
        MeshStores, RefusingGroupRatchetWrites
    ) {
        let (base, _) = try storesRefusingRows(blobs: blobs, failures: failures)
        let refuse: @Sendable () -> Void
        if let memory = base.transactor as? MemoryTransactor {
            refuse = { memory.failCurrentUnit() }
        } else {
            let groups = base.groups
            refuse = {
                // A roster naming a member twice breaks its key: the write SQLite refuses, inside the open unit.
                let member = GroupMember(nodeId: "refused")
                groups.save(GroupRecord(id: "g-refused", createdBy: "refused", createdAt: 1, roster: [member, member]))
            }
        }
        let refusing = RefusingGroupRatchetWrites(base.groupRatchet, refuse: refuse)
        let stores = MeshStores(
            custody: base.custody,
            peers: base.peers,
            messages: base.messages,
            conversations: base.conversations,
            blocks: base.blocks,
            groups: base.groups,
            ownProfile: base.ownProfile,
            blobs: base.blobs,
            ratchet: base.ratchet,
            groupRatchet: refusing,
            transactor: base.transactor
        )
        return (stores, refusing)
    }
}
