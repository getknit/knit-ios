import KnitCrypto
import KnitStore
import KnitStoreSQL
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The group facade's store, of either kind, with the unit it commits in: a ``MemoryGroupRatchetStore`` under a
/// ``MemoryTransactor``, or the SQL store on a database in memory, whose unit is the database itself (ADR 2026-10.5sk9's
/// P4a amendment). Each kind can fail the unit it is in as a store's error does: in memory a failing store double's
/// call, on the database a roster naming a member twice, which breaks `group_members`' key as a full disk would.
enum GroupSessionKind: CaseIterable, Sendable, CustomTestStringConvertible {
    case memory
    case sql

    /// One store and its unit.
    struct Made {
        let store: any GroupRatchetStore
        let transactor: any StoreTransactor
        private let groups: any GroupStore

        init(store: any GroupRatchetStore, transactor: any StoreTransactor, groups: any GroupStore) {
            self.store = store
            self.transactor = transactor
            self.groups = groups
        }

        /// A facade for `nodeId` over this store.
        func sessions(_ nodeId: NodeId, engine: GroupRatchetEngine = GroupRatchetEngine()) -> GroupRatchetSessions {
            GroupRatchetSessions(nodeId: nodeId, store: store, transactor: transactor, engine: engine)
        }

        /// Fails the unit open now, as a store's error inside it does.
        func failCurrentUnit() {
            guard let memory = transactor as? MemoryTransactor else {
                let member = GroupMember(nodeId: fixtureNodeId(9).string)
                groups.save(GroupRecord(id: "g-refused", createdBy: member.nodeId, createdAt: 1, roster: [member, member]))
                return
            }
            memory.failCurrentUnit()
        }
    }

    var testDescription: String {
        switch self {
        case .memory:
            "memory"
        case .sql:
            "sql"
        }
    }

    /// A fresh store.
    func make() throws -> Made {
        switch self {
        case .memory:
            let store = MemoryGroupRatchetStore()
            let groups = MemoryGroupStore()
            return Made(store: store, transactor: MemoryTransactor(stores: [store, groups]), groups: groups)
        case .sql:
            let database = try KnitDatabase.inMemory { _ in
                // Only ``Made/failCurrentUnit()`` fails the database, and the facade's answer is what a test reads.
            }
            return Made(store: SQLGroupRatchetStore(database), transactor: database, groups: SQLGroupStore(database))
        }
    }
}
