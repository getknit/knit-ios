import Foundation
import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

// v24, our own presence keys, tests here, so `SchemaTests+V23` stays small.

extension SchemaTests {
    @Test func v24KeepsEveryPeersKeysAndStartsWithNoKeyOfOurs() throws {
        // Nothing kept a key of ours before v24 (ADR 2026-11.prsp): a contact's key comes through, none of ours is held,
        // and the first one stored after the update reads back whole, its mark written durably.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v23")
        let bob = fixtureNodeId(2)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO peer_presence_keys (nodeId, generation, key, receivedAt, rootTag) VALUES (?, 7, ?, 9, -3)",
                arguments: [StoredText.bytes(bob.string), Data(fixtureBytes(32, seed: 4))]
            )
        }
        try Schema.migrator.migrate(queue)
        let keys = SQLPresenceKeyStore(try KnitDatabase(writer: queue, failures: recordFailure))
        #expect(keys.keys(of: bob).map(\.held.generation) == [7])
        #expect(keys.ownKeys().isEmpty)
        let row = try #require(
            OwnPresenceKeyRecord(
                generation: 1_756_200_000_000, keyBytes: fixtureBytes(32, seed: 5), mintedAt: 3, activatedAt: 4, audience: [bob], mark: nil)
        )
        keys.applyOwn(inserted: [row], updated: [], keep: [row.generation])
        #expect(keys.ownKeys() == [row])
        #expect(keys.writeMark(PresenceMark(slot: 11, restart: 1), of: row.generation) == .durable)
        #expect(keys.mark(of: row.generation) == PresenceMark(slot: 11, restart: 1))
    }

    @Test func anOwnKeyRowThatIsNotOneFailsTheReadRatherThanReadingAsNone() throws {
        // Only a damaged file holds one: a short key, or an audience naming anything but node ids.
        let failures = Failures()
        let database = try KnitDatabase.inMemory(failures: failures.record)
        try database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO own_presence_keys (generation, key, mintedAt, audience) VALUES (1, ?, 1, ?)",
                arguments: [Data([1, 2, 3]), StoredText.bytes("")])
        }
        let keys = SQLPresenceKeyStore(database)
        #expect(keys.ownKeys().isEmpty)
        #expect(failures.count == 1)
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE own_presence_keys SET key = ?, audience = ?",
                arguments: [Data(fixtureBytes(32, seed: 1)), StoredText.bytes("nope")])
        }
        #expect(keys.ownKeys().isEmpty)
        #expect(failures.count == 2)
        let unit = database.atomically { () -> Int? in keys.ownKeys().count }
        #expect(unit == .failed)
    }

    /// The mark's write leaves the connection at NORMAL, what the pool runs otherwise, whatever it came to.
    @Test func aMarkWriteLeavesTheConnectionAtNormal() throws {
        let database = try KnitDatabase.inMemory(failures: recordFailure)
        let keys = SQLPresenceKeyStore(database)
        let row = try #require(
            OwnPresenceKeyRecord(generation: 5, keyBytes: fixtureBytes(32, seed: 5), mintedAt: 1, activatedAt: 1, audience: [], mark: nil))
        keys.applyOwn(inserted: [row], updated: [], keep: [5])
        #expect(keys.writeMark(PresenceMark(slot: 1, restart: 0), of: 5) == .durable)
        #expect(keys.writeMark(PresenceMark(slot: 1, restart: 0), of: 6) == .refused)
        let level = try database.writer.writeWithoutTransaction { db in try Int64.fetchOne(db, sql: "PRAGMA synchronous") }
        #expect(level == 1)
    }
}
