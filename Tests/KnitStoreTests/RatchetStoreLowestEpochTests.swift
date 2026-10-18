import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The ratchet store's lowest local epoch over every store kind (`lowestLocalEpoch`, knit-next `RatchetStore.kt:29-34`,
/// `RatchetDao.kt:54-57` at `4f3cd995`), which the retired-base gate reads (knit-next ADR 2026-10.9wvr). Apart from
/// `RatchetStoreTests` only to keep that file inside the lint's length.
@Suite struct RatchetStoreLowestEpochTests {
    private static let now: Int64 = 1_700_000_000_000
    private let peer = fixtureNodeId(1)

    private func session(_ peer: NodeId, sendEpoch: Int) -> RatchetSessionRecord {
        RatchetSessionRecord(
            peerId: peer,
            confirmed: true,
            weAreInitiator: true,
            root: [UInt8](repeating: 1, count: 32),
            establishedAt: Self.now,
            sendEpoch: sendEpoch
        )
    }

    private func localEpoch(_ epoch: Int, createdAt: Int64) -> RatchetLocalEpochRecord {
        RatchetLocalEpochRecord(
            epoch: epoch, privateKey: [UInt8](repeating: 4, count: 32), publicKey: [UInt8](repeating: 5, count: 32), createdAt: createdAt)
    }

    /// The lowest number held, not the oldest mint, so a dead era's surviving high row beside the live era's low ones never
    /// raises it; one peer's rows never answer for another's, and a peer with none answers `nil`.
    @Test(arguments: RepositoryKind.allCases)
    func theLowestLocalEpochIsTheLowestNumberHeldNotTheOldestMint(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        let other = fixtureNodeId(9)
        #expect(ratchet.lowestLocalEpoch(peer) == nil)
        ratchet.commitSend(session(peer, sendEpoch: 14), newLocalEpoch: localEpoch(14, createdAt: Self.now - 3_600_000))
        ratchet.commitSend(session(peer, sendEpoch: 2), newLocalEpoch: localEpoch(2, createdAt: Self.now))
        ratchet.commitSend(session(peer, sendEpoch: 3), newLocalEpoch: localEpoch(3, createdAt: Self.now + 1))
        ratchet.commitSend(session(other, sendEpoch: 1), newLocalEpoch: localEpoch(1, createdAt: Self.now))
        #expect(ratchet.lowestLocalEpoch(peer) == 2, "the live era's 2, under the dead era's older 14")
        #expect(ratchet.lowestLocalEpoch(other) == 1)
        ratchet.deletePeer(other)
        #expect(ratchet.lowestLocalEpoch(other) == nil)
    }
}
