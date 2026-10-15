import Foundation
import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

// Migrations from v16 on test here, so `SchemaTests+V15` stays small.

extension SchemaTests {
    @Test func v16KeepsEveryPeerWithNoPrekeyAndOurProfileCarryingNone() throws {
        // Nobody had a prekey before v16 (ADR 2026-10.5sk9): every pin reads none, with a watermark of 0 that the peer's
        // next profile moves, and our own profile carries none until the ratchet's switch puts one on it.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v15")
        let bob = fixtureNodeId(2)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO peers (nodeId, name, status, publicKey, capabilities, updatedAt, verified, openToChat)
                    VALUES (?, ?, ?, ?, 15, 7, 1, 0)
                    """,
                arguments: [StoredText.bytes(bob.string), StoredText.bytes("Bob"), StoredText.bytes(""), StoredText.bytes("key")]
            )
            try db.execute(
                sql: "INSERT INTO own_profile (slot, name, status, openToChat, version, publishedAt) VALUES (0, ?, ?, 0, 5, 6)",
                arguments: [StoredText.bytes("Me"), StoredText.bytes("")]
            )
        }
        try Schema.migrator.migrate(queue)
        let database = try KnitDatabase(writer: queue, failures: recordFailure)
        let peers = SQLPeerStore(database)
        let peer = try #require(peers.peer(bob))
        #expect(peer.name == "Bob" && peer.verified && peer.capabilities == 15 && peer.updatedAt == 7)
        #expect(peer.prekey == nil)
        #expect(peer.prekeyProfileAt == 0)
        #expect(SQLOwnProfileStore(database).load() == OwnProfile(name: "Me", version: 5, publishedAt: 6))
        // The first profile after the update pins its prekey.
        var pinned = peer
        pinned.prekey = PrekeyInfo(id: 1, pub: fixtureBytes(32, seed: 1), sig: fixtureBytes(64, seed: 2))
        pinned.prekeyProfileAt = 7
        peers.upsert(pinned)
        #expect(peers.peer(bob) == pinned)
    }

    @Test func aPrekeyMissingAnyOfItsColumnsReadsAsNone() throws {
        // Only this store writes the three together; a damaged row is no pin rather than half of one.
        let database = try KnitDatabase.inMemory(failures: recordFailure)
        let peers = SQLPeerStore(database)
        let bob = fixtureNodeId(2)
        let prekey = PrekeyInfo(id: 1, pub: fixtureBytes(32, seed: 1), sig: fixtureBytes(64, seed: 2))
        peers.upsert(PeerRecord(nodeId: bob, name: "", status: "", publicKey: "key", updatedAt: 1, prekey: prekey, prekeyProfileAt: 1))
        try database.writer.write { db in
            try db.execute(sql: "UPDATE peers SET prekeySig = NULL")
        }
        #expect(peers.peer(bob)?.prekey == nil)
        #expect(peers.peer(bob)?.prekeyProfileAt == 1)
    }
}
