import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The ratchet store's session listing over every store kind (`sessionPeerIds`, `RatchetStore.kt:20`, `RatchetDao.kt:24-25`,
/// at knit-next `cbf2a487`), which the sealed profile's fan-out to our confirmed sessions reads (ADR 2026-10.5sk9, phase
/// P5e). Apart from `RatchetStoreTests` only to keep that file inside the lint's length.
@Suite struct RatchetStoreSessionPeerIdsTests {
    private static let now: Int64 = 1_700_000_000_000

    /// A confirmed session with `peer`, every other field at its plainest.
    private func session(_ peer: NodeId) -> RatchetSessionRecord {
        RatchetSessionRecord(
            peerId: peer, confirmed: true, weAreInitiator: true, root: [UInt8](repeating: 1, count: 32), establishedAt: Self.now)
    }

    /// Every peer a session is held with, in node id order on both stores, Kotlin's query naming no order, and not one whose
    /// rows went.
    @Test(arguments: RepositoryKind.allCases)
    func sessionPeerIdsListEveryPeerHeldInNodeIdOrder(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        #expect(ratchet.sessionPeerIds().isEmpty)
        let peers = (1...3).map { fixtureNodeId($0) }
        for held in peers.reversed() {
            ratchet.upsertSession(session(held))
        }
        #expect(ratchet.sessionPeerIds() == peers.sorted())
        ratchet.deletePeer(peers[1])
        #expect(ratchet.sessionPeerIds() == [peers[0], peers[2]].sorted())
    }
}
