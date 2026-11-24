import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// `PeerRecord.lastSeenAt`, when a peer was last heard (knit-next ADR 2026-10.k8ge), over every peer store: it rides every
/// upsert without ever moving back, and ``PeerStore/markSeen(_:gate:)`` raises it past the gate alone, answering the rows it
/// changed (`PeerDaoTest`'s MAX-merge and `markSeen` cases).
@Suite struct PeerLastSeenStoreTests {
    private static let kinds = RepositoryKind.allCases
    private static let gate: Int64 = 6 * 3_600_000

    private let bob = fixtureNodeId(2)
    private let carol = fixtureNodeId(3)
    private let stranger = fixtureNodeId(4)

    private func row(_ node: NodeId, lastSeenAt: Int64 = 0) -> PeerRecord {
        PeerRecord(nodeId: node, name: "", status: "", publicKey: "key", updatedAt: 1, lastSeenAt: lastSeenAt)
    }

    @Test(arguments: kinds)
    func aRowKeepsItsStampAndAnUpsertRaisesIt(kind: RepositoryKind) throws {
        let store = try kind.make().peers
        store.upsert(row(bob, lastSeenAt: 40))
        #expect(store.peer(bob)?.lastSeenAt == 40)
        store.upsert(row(bob, lastSeenAt: 90))
        #expect(store.peer(bob)?.lastSeenAt == 90)
        #expect(store.allPeers().map(\.lastSeenAt) == [90])
    }

    @Test(arguments: kinds)
    func anUpsertOfACopyReadBeforeABankNeverTakesItsStampBack(kind: RepositoryKind) throws {
        // Every engine writer reads the row, changes a field and writes it back: a bank in between must survive it.
        let store = try kind.make().peers
        store.upsert(row(bob))
        var stale = try #require(store.peer(bob))
        #expect(store.markSeen([bob: Self.gate * 2], gate: Self.gate) == [bob])
        stale.name = "Bob"
        store.upsert(stale)
        let held = try #require(store.peer(bob))
        #expect(held.lastSeenAt == Self.gate * 2, "the larger stamp stays")
        #expect(held.name == "Bob", "every other field takes the write")
    }

    @Test(arguments: kinds)
    func markSeenRaisesOnlyPastTheGateAndAnswersTheRowsItChanged(kind: RepositoryKind) throws {
        let store = try kind.make().peers
        store.upsert(row(bob, lastSeenAt: 1000))
        store.upsert(row(carol, lastSeenAt: 1000))
        // At the gate exactly is inside it (`lastSeenAt < at - gate`); one past it is out; a node with no row writes nothing.
        let changed = store.markSeen([bob: 1000 + Self.gate, carol: 1001 + Self.gate, stranger: 5 * Self.gate], gate: Self.gate)
        #expect(changed == [carol])
        #expect(store.lastSeenStamps() == [bob: 1000, carol: 1001 + Self.gate])
        #expect(store.peer(stranger) == nil, "a stamp never makes a row")
        #expect(store.markSeen([:], gate: Self.gate)?.isEmpty == true, "an empty bank changes nothing and does not fail")
    }

    @Test(arguments: kinds)
    func markSeenNeverTrapsOnAStampAtEitherEnd(kind: RepositoryKind) throws {
        // The peer picks `sentAt`. A stamp whose threshold would overflow raises nothing.
        let store = try kind.make().peers
        store.upsert(row(bob, lastSeenAt: 7))
        #expect(store.markSeen([bob: .min], gate: Self.gate)?.isEmpty == true)
        #expect(store.markSeen([bob: .min + 1, carol: -1], gate: Self.gate)?.isEmpty == true)
        #expect(store.peer(bob)?.lastSeenAt == 7)
        #expect(store.markSeen([bob: .max], gate: Self.gate) == [bob])
        #expect(store.peer(bob)?.lastSeenAt == .max)
        #expect(store.markSeen([bob: .max], gate: Self.gate)?.isEmpty == true, "held at the top, nothing is older")
    }

    @Test func theThresholdIsNilWhereTheSubtractionWouldOverflow() {
        #expect(PeerRecord.seenThreshold(at: .min, gate: Self.gate) == nil)
        #expect(PeerRecord.seenThreshold(at: .min + Self.gate, gate: Self.gate) == .min)
        #expect(PeerRecord.seenThreshold(at: 0, gate: Self.gate) == -Self.gate)
    }
}
