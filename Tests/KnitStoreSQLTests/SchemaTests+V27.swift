import Foundation
import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

// v27-peer-last-seen, when each peer was last heard, tests here, so `SchemaTests+V26` stays small.

extension SchemaTests {
    @Test func v27SeedsLastSeenAtFromTheLaterOfTheWatermarkAndTheKeptProof() throws {
        // knit-next's `migrate 18 to 19 seeds lastSeenAt…` (`KnitDatabaseMigrationTest.kt:655-673`): a kept proof newer
        // than the version wins, a version newer than the proof wins, and a row with no proof takes its version. A fourth
        // row, this port's own, has a peer-picked negative watermark and no proof, and is floored at 0.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v26-prev-root-own-init")
        let (live, edited, bare, negative) = (fixtureNodeId(2), fixtureNodeId(3), fixtureNodeId(4), fixtureNodeId(5))
        try queue.write { db in
            for (node, updatedAt) in [(live, Int64(10)), (edited, 50), (bare, 7), (negative, -9)] {
                try db.execute(
                    sql: """
                        INSERT INTO peers (nodeId, name, status, publicKey, updatedAt, verified, openToChat)
                        VALUES (?, ?, ?, ?, ?, 0, 0)
                        """,
                    arguments: [
                        StoredText.bytes(node.string), StoredText.bytes("n"), StoredText.bytes(""), StoredText.bytes("k"), updatedAt,
                    ]
                )
            }
            for (node, sentAt) in [(live, Int64(40)), (edited, 20)] {
                try db.execute(
                    sql: "INSERT INTO peer_profiles (nodeId, signed, sig, sentAt) VALUES (?, ?, ?, ?)",
                    arguments: [StoredText.bytes(node.string), Data([1]), Data([2]), sentAt]
                )
            }
        }
        try Schema.migrator.migrate(queue)
        let applied = try queue.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied.contains("v27-peer-last-seen") && !applied.contains("v27"), "registered under its name, never a bare v27")
        let peers = SQLPeerStore(try KnitDatabase(writer: queue, failures: recordFailure))
        #expect(peers.lastSeenStamps() == [live: 40, edited: 50, bare: 7, negative: 0])
        // Every other column comes through as it was.
        #expect(peers.peer(edited)?.updatedAt == 50)
        #expect(peers.peer(edited)?.name == "n")
        #expect(peers.peer(live)?.lastSeenAt == 40)
    }
}
