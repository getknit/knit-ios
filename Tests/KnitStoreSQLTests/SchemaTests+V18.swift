import Foundation
import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

// Migrations from v18 on test here, so `SchemaTests+V17` stays small.

extension SchemaTests {
    @Test func v18KeepsEveryGroupAndSessionAndStartsWithNoGroupRatchetState() throws {
        // Nothing held group-ratchet state before v18 (ADR 2026-10.5sk9): every group and its roster and every DM session
        // come through, and every group reads as one we hold no chain, key or outbox row for, as a reinstall's does.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v17")
        let bob = fixtureNodeId(2)
        let group = "g-0123456789abcdef01234567"
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO groups (groupId, name, createdBy, createdAt, nameUpdatedAt, hasLeft) VALUES (?, ?, ?, 7, 7, 0)",
                arguments: [StoredText.bytes(group), StoredText.bytes("Hike"), StoredText.bytes(bob.string)]
            )
            try db.execute(
                sql: "INSERT INTO group_members (groupId, nodeId, position, departed) VALUES (?, ?, 0, 0)",
                arguments: [StoredText.bytes(group), StoredText.bytes(bob.string)]
            )
            try db.execute(
                sql: """
                    INSERT INTO ratchet_sessions (peerId, confirmed, weAreInitiator, root, prevRootWeAreInitiator, prevRootExpiresAt,
                        establishedAt, initPkid, peerBaseEpoch, sendEpoch, sendCount, sendEpochStartedAt, sendEpochBaseEpoch,
                        highestPeAcked, lastResetSentAt)
                    VALUES (?, 1, 0, ?, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 0)
                    """,
                arguments: [StoredText.bytes(bob.string), Data(fixtureBytes(32, seed: 3))]
            )
        }
        try Schema.migrator.migrate(queue)
        let database = try KnitDatabase(writer: queue, failures: recordFailure)
        #expect(SQLGroupStore(database).group(group)?.roster.map(\.nodeId) == [bob.string])
        #expect(SQLRatchetStore(database).session(bob)?.root == fixtureBytes(32, seed: 3))
        let store = SQLGroupRatchetStore(database)
        #expect(store.holdings(of: group) == .empty)
        #expect(store.sendChain(group) == nil)
        // The first group state after the update is kept whole.
        let chain = GroupSendChainRecord(
            epoch: 1, seed: fixtureBytes(32, seed: 4), chainKey: fixtureBytes(32, seed: 5), count: 1, mintedAt: 7)
        store.commitSend(chain, in: group)
        store.markKeySent(group, to: bob, epoch: 1, at: 8)
        #expect(store.sendChain(group) == chain)
        #expect(store.keySends(group) == [GroupKeySendRecord(member: bob, sentEpoch: 1, sentAt: 8, ackedEpoch: 0, ackedAt: 0)])
    }
}
