import Foundation
import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

extension SchemaTests {
    @Test func v22KeepsEveryPeerAndStartsWithNoPresenceKey() throws {
        // Nothing held a presence key before v22 (ADR 2026-11.sv5t): every pin comes through, nobody's key is held, and the
        // first key stored after the update reads back whole.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v21")
        let bob = fixtureNodeId(2)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO peers (nodeId, name, status, publicKey, capabilities, updatedAt, verified, openToChat)
                    VALUES (?, ?, ?, ?, 351, 7, 1, 1)
                    """,
                arguments: [StoredText.bytes(bob.string), StoredText.bytes("Bob"), StoredText.bytes(""), StoredText.bytes("key")]
            )
        }
        try Schema.migrator.migrate(queue)
        let database = try KnitDatabase(writer: queue, failures: recordFailure)
        let peer = try #require(SQLPeerStore(database).peer(bob))
        #expect(peer.name == "Bob" && peer.verified)
        let keys = SQLPresenceKeyStore(database)
        #expect(keys.peersWithKeys().isEmpty && keys.keys(of: bob).isEmpty)
        let stored = try #require(
            StoredPresenceKey(generation: 1_756_200_000_000, keyBytes: fixtureBytes(32, seed: 4), rootTag: -3, receivedAt: 9))
        keys.replaceKeys(of: bob, with: [stored.held], now: 9)
        #expect(keys.keys(of: bob) == [stored])
    }

    @Test func aStoredKeyThatIsNotOneFailsTheReadRatherThanReadingAsNone() throws {
        // Only a damaged file holds one, so the read reports it, and inside a unit fails it, rather than reading as no key.
        let failures = Failures()
        let database = try KnitDatabase.inMemory(failures: failures.record)
        let bob = fixtureNodeId(2)
        try database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO peer_presence_keys (nodeId, generation, key, receivedAt, rootTag) VALUES (?, 1, ?, 1, 1)",
                arguments: [StoredText.bytes(bob.string), Data([1, 2, 3])]
            )
        }
        let keys = SQLPresenceKeyStore(database)
        #expect(keys.keys(of: bob).isEmpty)
        #expect(failures.count == 1)
        let unit = database.atomically { () -> Int? in keys.keys(of: bob).count }
        #expect(unit == .failed)
    }
}
