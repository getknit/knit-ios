import Foundation
import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

// v26-prev-root-own-init, the stamp of our own init a race loser keeps draining, tests here, so `SchemaTests+V25` stays
// small.

extension SchemaTests {
    @Test func v26KeepsEverySessionAndStampsNoneOfThemOurOwnInit() throws {
        // No build before it recorded the stamp (knit-next ADR 2026-10.4mjm): a session row comes through whole and reads no
        // stamp, so a session that lost its race before the update never reclaims, as before.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v25-own-profile-frame")
        let bob = fixtureNodeId(2)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ratchet_sessions (peerId, confirmed, weAreInitiator, root, prevRoot, prevRootWeAreInitiator,
                        prevRootExpiresAt, establishedAt, initEphPub, initPkid, peerInitEphPub, peerBasePub, peerBaseEpoch, sendEpoch,
                        sendEpochPub, sendChainKey, sendCount, sendEpochStartedAt, sendEpochBaseEpoch, highestPeAcked, lastResetSentAt)
                    VALUES (?, 1, 0, ?, ?, 1, 9, 7, NULL, 1, ?, NULL, 0, 2, ?, ?, 3, 8, 0, 1, 0)
                    """,
                arguments: [
                    StoredText.bytes(bob.string), Data(fixtureBytes(32, seed: 1)), Data(fixtureBytes(32, seed: 2)),
                    Data(fixtureBytes(32, seed: 3)), Data(fixtureBytes(32, seed: 4)), Data(fixtureBytes(32, seed: 5)),
                ]
            )
        }
        try Schema.migrator.migrate(queue)
        let applied = try queue.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied.contains("v26-prev-root-own-init") && !applied.contains("v26"), "registered under its name, never a bare v26")
        let ratchet = SQLRatchetStore(try KnitDatabase(writer: queue, failures: recordFailure))
        let expected = RatchetSessionRecord(
            peerId: bob,
            confirmed: true,
            weAreInitiator: false,
            root: fixtureBytes(32, seed: 1),
            prevRoot: fixtureBytes(32, seed: 2),
            prevRootWeAreInitiator: true,
            prevRootExpiresAt: 9,
            prevRootOwnInitAt: nil,
            establishedAt: 7,
            initPkid: 1,
            peerInitEphPub: fixtureBytes(32, seed: 3),
            sendEpoch: 2,
            sendEpochPub: fixtureBytes(32, seed: 4),
            sendChainKey: fixtureBytes(32, seed: 5),
            sendCount: 3,
            sendEpochStartedAt: 8,
            highestPeAcked: 1
        )
        #expect(ratchet.session(bob) == expected)
        // The stamp a race loser writes after the update comes back as it went in.
        var stamped = expected
        stamped.prevRootOwnInitAt = 6
        ratchet.upsertSession(stamped)
        #expect(ratchet.session(bob) == stamped)
    }
}
