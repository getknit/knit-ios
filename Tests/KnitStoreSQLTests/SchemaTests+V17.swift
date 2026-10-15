import Foundation
import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

// Migrations from v17 on test here, so `SchemaTests+V16` stays small.

extension SchemaTests {
    @Test func v17KeepsEveryPeerAndStartsWithNoRatchetState() throws {
        // Nothing held a ratchet session before v17 (ADR 2026-10.5sk9): every pin, its prekey included, comes through, and
        // every peer reads as one we hold no session with, which a reinstall's database does too.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v16")
        let bob = fixtureNodeId(2)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO peers (nodeId, name, status, publicKey, capabilities, updatedAt, verified, openToChat, prekeyId,
                        prekeyPub, prekeySig, prekeyProfileAt)
                    VALUES (?, ?, ?, ?, 351, 7, 0, 1, 4, ?, ?, 7)
                    """,
                arguments: [
                    StoredText.bytes(bob.string), StoredText.bytes("Bob"), StoredText.bytes(""), StoredText.bytes("key"),
                    Data(fixtureBytes(32, seed: 1)), Data(fixtureBytes(64, seed: 2)),
                ]
            )
        }
        try Schema.migrator.migrate(queue)
        let database = try KnitDatabase(writer: queue, failures: recordFailure)
        let peer = try #require(SQLPeerStore(database).peer(bob))
        #expect(peer.name == "Bob" && peer.capabilities == 351 && peer.prekeyProfileAt == 7)
        #expect(peer.prekey == PrekeyInfo(id: 4, pub: fixtureBytes(32, seed: 1), sig: fixtureBytes(64, seed: 2)))
        let ratchet = SQLRatchetStore(database)
        #expect(ratchet.session(bob) == nil)
        #expect(ratchet.records(of: bob) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
        // The first session after the update is kept whole.
        let session = RatchetSessionRecord(
            peerId: bob, confirmed: true, weAreInitiator: false, root: fixtureBytes(32, seed: 3), establishedAt: 7)
        ratchet.upsertSession(session)
        #expect(ratchet.session(bob) == session)
    }
}
