import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// A reclaim's purge over every store kind (knit-next ADR 2026-10.4mjm; `RatchetDao.deleteRecvEpochsForExcept` and
/// `deleteSkippedKeysForExcept`, `RatchetDao.kt:87-92`, `:132-137` at `f018bc8ce`). Apart from `RatchetStoreTests` only to
/// keep that file inside the lint's length.
@Suite struct RatchetStoreReclaimPurgeTests {
    private static let now: Int64 = 1_700_000_000_000
    private static let kept: Int64 = -0x1051_E503
    private static let left: Int64 = 0x7EA2_D2A5
    private let peer = fixtureNodeId(1)

    private func open(_ ratchet: any RatchetStore, epoch: Int, tag: Int64, skipped: Bool, purgeKeeping keep: Int64? = nil) {
        var session = RatchetSessionRecord(
            peerId: peer, confirmed: true, weAreInitiator: true, root: [UInt8](repeating: 1, count: 32), establishedAt: Self.now)
        session.prevRootOwnInitAt = keep.map { _ in Self.now - 1 }
        let key = RatchetSkippedKeyRecord(
            epoch: epoch, rootTag: tag, index: 1, messageKey: [UInt8](repeating: 3, count: 32), createdAt: Self.now)
        ratchet.applyOpen(
            RatchetOpenDelta(
                session: session,
                recvEpoch: RatchetRecvEpochRecord(
                    epoch: epoch, rootTag: tag, chainKey: [UInt8](repeating: 2, count: 32), next: 3, lastUsedAt: Self.now),
                skippedInserts: skipped ? [key] : [],
                purgePeerRecvState: keep != nil,
                keepRecvTag: keep
            ),
            from: peer,
            se: epoch,
            n: 2
        )
    }

    /// Every chain and skipped key goes but the reclaimed root's, whose rows are the era the session moves back to, and the
    /// chain the open writes after the purge stands beside them.
    @Test(arguments: RepositoryKind.allCases)
    func aReclaimsPurgeKeepsTheReclaimedRootsChainsAndKeys(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        open(ratchet, epoch: 1, tag: Self.kept, skipped: true)
        open(ratchet, epoch: 1, tag: Self.left, skipped: true)
        open(ratchet, epoch: 2, tag: Self.kept, skipped: false, purgeKeeping: Self.kept)
        #expect(ratchet.recvEpochs(peer, epoch: 1).map(\.rootTag) == [Self.kept], "the other root's chain went")
        #expect(ratchet.skippedKeys(peer, epoch: 1, index: 1).map(\.rootTag) == [Self.kept], "and its skipped key")
        #expect(ratchet.recvEpochs(peer, epoch: 2).map(\.rootTag) == [Self.kept], "the open's own chain stands")
        #expect(ratchet.session(peer)?.prevRootOwnInitAt == Self.now - 1)
    }
}
