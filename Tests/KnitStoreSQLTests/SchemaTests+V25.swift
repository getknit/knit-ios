import Foundation
import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

// v25-own-profile-frame, the frame our profile was published as, tests here, so `SchemaTests+V24` stays small.

extension SchemaTests {
    @Test func v25OwnProfileFrameKeepsOurProfileAndKeepsNoFrame() throws {
        // Nothing kept our published frame before it (ADR 2026-11.xfcq): the profile comes through whole, no frame is kept,
        // and the first start takes custody's row as the kept frame, or signs once when the row is gone.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v24")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO own_profile (slot, name, status, openToChat, version, publishedAt, avatarHash, prekeyId, capabilities)
                    VALUES (0, ?, ?, 1, 5, 6, NULL, 2, ?)
                    """,
                arguments: [StoredText.bytes("Me"), StoredText.bytes("here"), Int64(0x1C015F)]
            )
        }
        try Schema.migrator.migrate(queue)
        let applied = try queue.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied.contains("v25-own-profile-frame") && !applied.contains("v25"), "registered under its name, never a bare v25")
        let store = SQLOwnProfileStore(try KnitDatabase(writer: queue, failures: recordFailure))
        var expected = OwnProfile(name: "Me", status: "here", openToChat: true, version: 5, publishedAt: 6, prekeyId: 2)
        expected.capabilities = Capabilities(rawValue: 0x1C015F)
        #expect(store.load() == expected)
        #expect(store.keptFrame() == .absent)
    }

    @Test func aKeptFrameThatCannotBeReadIsNeverTakenForNoneKept() throws {
        // "None kept" lets the engine sign the stamp; a read that failed must not (ADR 2026-11.xfcq).
        let failures = Failures()
        let queue = try DatabaseQueue()
        let database = try KnitDatabase(writer: queue, failures: failures.record)
        let store = SQLOwnProfileStore(database)
        let frame = WireEnvelope(sig: fixtureBytes(64, seed: 1), signed: [0x00] + fixtureBytes(300, seed: 2))
        #expect(store.keep(frame) && store.keptFrame() == .kept(frame))
        try queue.write { db in
            try db.execute(sql: "DROP TABLE own_profile_frame")
        }
        #expect(store.keptFrame() == .unreadable)
        #expect(!store.keep(frame), "a write that failed says so")
        #expect(failures.count == 2)
        let inUnit = database.atomically { () -> KeptProfileFrame? in store.keptFrame() }
        #expect(inUnit == .failed, "inside a unit the failed read fails the unit")
    }

    @Test func aKeptFrameBoundAsTextIsRefused() throws {
        // Both columns are BLOBs in a STRICT table, so a frame bound by mistake as a string fails loudly.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue)
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO own_profile_frame (slot, sig, signed) VALUES (0, 'sig', 'signed')")
            }
        }
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO own_profile_frame (slot, sig, signed) VALUES (1, x'00', x'00')")
            }
        }
    }
}
