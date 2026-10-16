import KnitCrypto
import KnitStore
import KnitStoreSQL
import KnitSync
import KnitWire
import Testing

@testable import KnitMesh

/// The session facade over the database, whose unit is the `KnitDatabase` itself, since the memory and SQL transactors
/// once disagreed (ADR 2026-10.5sk9's P4a amendment): a row the database refuses inside an open's unit takes the open
/// with it, no floor moves, and the same frame opens once the store heals, as P5a's sweep opens the copy that failed; and
/// the era gate's unit, failed by the database, counts nothing.
@Suite struct RatchetSessionsDatabaseTests {
    static let now: Int64 = 1_700_000_000_000

    @Test func aRowTheDatabaseRefusesTakesTheOpenWithItAndTheFrameOpensOnReplay() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let failures = Failures()
        let database = try KnitDatabase.inMemory(failures: failures.record)
        let ratchet = SQLRatchetStore(database)
        let groups = SQLGroupStore(database)
        let sessions = RatchetSessions(identity: bob.identity, store: ratchet, transactor: database)
        let frame = try #require(RatchetSessions.Frame(envelope: alice.seal("hello", now: Self.now), aad: RatchetSessionSide.aad))
        let prekeys = bob.prekeys

        // The row the open carries, refused as a full disk refuses it: a roster naming a member twice breaks its key.
        let member = GroupMember(nodeId: alice.nodeId.string)
        let refused = GroupRecord(id: "g-refused", createdBy: alice.nodeId.string, createdAt: 1, roster: [member, member])
        let failed = sessions.open(
            frame,
            from: alice.identity.bundle,
            now: Self.now,
            prekeys: { prekeys[$0] },
            alongside: { _ in
                groups.save(refused)
                return ()
            }
        )
        guard case .failed = failed else {
            Issue.record("a refused row fails the open: \(failed)")
            return
        }
        #expect(ratchet.records(of: alice.nodeId) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
        #expect(failures.count == 1, "the database reports its error once")

        let healed = GroupRecord(id: "g-healed", createdBy: alice.nodeId.string, createdAt: 1, roster: [member])
        let replayed = sessions.open(
            frame,
            from: alice.identity.bundle,
            now: Self.now,
            prekeys: { prekeys[$0] },
            alongside: { _ in
                groups.save(healed)
                return ()
            }
        )
        guard case .settled(.opened(let plaintext, _)) = replayed else {
            Issue.record("the same frame opens once the store heals: \(replayed)")
            return
        }
        #expect(plaintext == Array("hello".utf8))
        #expect(ratchet.session(alice.nodeId)?.confirmed == true)
        #expect(groups.group("g-healed") != nil, "the caller's row stands with the open")
    }

    /// The era gate's read on the database: a unit the database has failed cannot say which era the session is in, so
    /// the frame counts nothing and never joins the heuristic's ids, as a memory store that refuses the read shows
    /// (`RatchetSessionsEvidenceTests`). A verdict reached on a store's fallback is no evidence.
    @Test func aGateWhoseUnitTheDatabaseFailedCountsNothing() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let failures = Failures()
        let database = try KnitDatabase.inMemory(failures: failures.record)
        let groups = SQLGroupStore(database)
        let sessions = RatchetSessions(identity: bob.identity, store: SQLRatchetStore(database), transactor: database)
        let member = GroupMember(nodeId: alice.nodeId.string)
        var counted: [Bool] = []
        let outer = database.atomically { () -> Int? in
            groups.save(GroupRecord(id: "g-refused", createdBy: alice.nodeId.string, createdAt: 1, roster: [member, member]))
            for id in ["a", "b", "c"] {
                counted.append(sessions.noteUndecryptable(from: alice.nodeId, frameId: id, sentAt: Self.now, now: Self.now))
            }
            return 1
        }
        #expect(outer == .failed)
        #expect(counted == [false, false, false])
        #expect(sessions.floors(for: alice.nodeId).undecryptableIds == 0)
        #expect(failures.count == 1, "the database reports its error once")

        #expect(!sessions.noteUndecryptable(from: alice.nodeId, frameId: "a", sentAt: Self.now, now: Self.now))
        #expect(!sessions.noteUndecryptable(from: alice.nodeId, frameId: "b", sentAt: Self.now, now: Self.now))
        #expect(sessions.noteUndecryptable(from: alice.nodeId, frameId: "c", sentAt: Self.now, now: Self.now))
    }

    /// The gate's read joined to a healthy caller's unit on the database: it counts nothing, since a joined open or
    /// reset clears the heuristic's ids only once that unit commits (`RatchetSessionsEvidenceTests` for the memory store).
    @Test func aGateReadInsideAHealthyUnitCountsNothing() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let database = try KnitDatabase.inMemory { _ in Issue.record("the database reports nothing") }
        let sessions = RatchetSessions(identity: bob.identity, store: SQLRatchetStore(database), transactor: database)
        var counted: [Bool] = []
        let outer = database.atomically { () -> Int? in
            for id in ["a", "b", "c"] {
                counted.append(sessions.noteUndecryptable(from: alice.nodeId, frameId: id, sentAt: Self.now, now: Self.now))
            }
            return 1
        }
        #expect(outer == .committed(1))
        #expect(counted == [false, false, false])
        #expect(sessions.floors(for: alice.nodeId).undecryptableIds == 0)

        #expect(!sessions.noteUndecryptable(from: alice.nodeId, frameId: "a", sentAt: Self.now, now: Self.now))
        #expect(!sessions.noteUndecryptable(from: alice.nodeId, frameId: "b", sentAt: Self.now, now: Self.now))
        #expect(sessions.noteUndecryptable(from: alice.nodeId, frameId: "c", sentAt: Self.now, now: Self.now))
    }
}

/// Counts the errors a database reported.
private final class Failures: Sendable {
    private let reported = Lock(0)

    var count: Int { reported.withLock { $0 } }

    @Sendable func record(_: any Error) {
        reported.withLock { $0 += 1 }
    }
}
