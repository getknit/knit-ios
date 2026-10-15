import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStore

/// The ratchet's retention as pure rules, which both stores apply (`RatchetRepository.sweep` and its constants, knit-next
/// `data/ratchet/RatchetRepository.kt:121-157`, `:213-224`, at `ac491f4c`).
@Suite struct RatchetRetentionTests {
    private static let now: Int64 = 1_700_000_000_000
    private static let hour: Int64 = 3_600_000

    @Test func theWindowsAreAndroids() {
        #expect(RatchetRetention.skippedKeyMilliseconds == 48 * Self.hour)
        #expect(RatchetRetention.receiveChainMilliseconds == 48 * Self.hour)
        #expect(RatchetRetention.maxSkippedKeys == 2000)
        #expect(RatchetRetention.keptLocalEpochs == 3)
        #expect(RatchetRetention.maxLocalEpochs == 16)
        #expect(RatchetRetention.localEpochRetireMilliseconds == 48 * Self.hour)
        #expect(RatchetRetention.localEpochLifetimeMilliseconds == 30 * 24 * Self.hour)
    }

    @Test func theCutoffsLookFortyEightHoursBackAndWrapAsKotlinsLongDoes() {
        #expect(RatchetRetention.skippedKeyCutoff(now: Self.now) == Self.now - 48 * Self.hour)
        #expect(RatchetRetention.receiveChainCutoff(now: Self.now) == Self.now - 48 * Self.hour)
        #expect(RatchetRetention.skippedKeyCutoff(now: .min) == Int64.min &- 48 * Self.hour, "a clock at the edge never traps")
        #expect(RatchetRetention.receiveChainCutoff(now: .min) == Int64.min &- 48 * Self.hour)
    }

    @Test func theCapEvictsOnlyWhatIsOverIt() {
        #expect(RatchetRetention.skippedKeyExcess(count: 0) == 0)
        #expect(RatchetRetention.skippedKeyExcess(count: 2000) == 0)
        #expect(RatchetRetention.skippedKeyExcess(count: 2003) == 3)
        let keys = (0..<2000).map { stamp(fixtureNodeId(1), epoch: 1, index: $0, createdAt: Self.now) }
        #expect(RatchetRetention.evictedSkippedKeys(keys).isEmpty)
        let old = stamp(fixtureNodeId(2), epoch: 9, index: 9, createdAt: Self.now - 1)
        #expect(RatchetRetention.evictedSkippedKeys(keys + [old]) == [old], "one over: the oldest goes, whatever its key")
    }

    @Test func aTieInAgeGoesByPeerEpochIndexThenRootTag() {
        let peers = [fixtureNodeId(1), fixtureNodeId(2)].sorted()
        let low = peers[0]
        let high = peers[1]
        // In eviction order.
        let ordered = [
            stamp(high, epoch: 9, index: 9, rootTag: 9, createdAt: Self.now - 1),
            stamp(low, epoch: 1, index: 0, rootTag: -1, createdAt: Self.now),
            stamp(low, epoch: 1, index: 0, rootTag: 1, createdAt: Self.now),
            stamp(low, epoch: 1, index: 1, rootTag: 0, createdAt: Self.now),
            stamp(low, epoch: 2, index: 0, rootTag: 0, createdAt: Self.now),
            stamp(high, epoch: 1, index: 0, rootTag: 0, createdAt: Self.now),
        ]
        for (index, earlier) in ordered.enumerated() {
            for later in ordered.dropFirst(index + 1) {
                #expect(RatchetRetention.evictsFirst(earlier, later), "\(earlier) before \(later)")
                #expect(!RatchetRetention.evictsFirst(later, earlier))
            }
        }
        let filler = (0..<RatchetRetention.maxSkippedKeys - 2).map { stamp(high, epoch: 100, index: $0, createdAt: Self.now) }
        #expect(RatchetRetention.evictedSkippedKeys(filler + ordered.reversed()) == Array(ordered.prefix(4)))
    }

    @Test func theNewestThreeAlwaysStayWhateverTheirAgeOrAck() {
        let epochs = [(epoch: 1, createdAt: Self.now - 40 * 24 * Self.hour), (epoch: 2, createdAt: Self.now - 40 * 24 * Self.hour)]
        #expect(RatchetRetention.retiredLocalEpochs(epochs, highestPeAcked: 9, now: Self.now).isEmpty)
    }

    @Test func pastTheNewestThreeAnEpochGoesOnceAckedAndFortyEightHoursOld() {
        let fresh = (4...6).map { (epoch: $0, createdAt: Self.now) }
        let old = Self.now - 48 * Self.hour
        let rest = [(epoch: 1, createdAt: old), (epoch: 2, createdAt: old + 1), (epoch: 3, createdAt: old)]
        // Epoch 3 is the ack itself, not below it; epoch 2 is a millisecond short of 48 h.
        #expect(RatchetRetention.retiredLocalEpochs(fresh + rest, highestPeAcked: 3, now: Self.now) == [1])
        #expect(RatchetRetention.retiredLocalEpochs(fresh + rest, highestPeAcked: 0, now: Self.now).isEmpty, "nothing acked")
    }

    @Test func pastTheNewestThreeAnEpochGoesAtThirtyDaysAckedOrNot() {
        let fresh = (4...6).map { (epoch: $0, createdAt: Self.now) }
        let lifetime = RatchetRetention.localEpochLifetimeMilliseconds
        let rest = [(epoch: 1, createdAt: Self.now - lifetime), (epoch: 2, createdAt: Self.now - lifetime + 1)]
        #expect(RatchetRetention.retiredLocalEpochs(fresh + rest, highestPeAcked: 0, now: Self.now) == [1])
    }

    @Test func theCapKeepsSixteenRankedByMintTimeNotNumber() {
        // A reset restarted the numbering: the live era's low numbers are the newest and must not be the ones the cap takes.
        let dead = (47...66).map { (epoch: $0, createdAt: Self.now - Self.hour + Int64($0)) }
        let live = (1...3).map { (epoch: $0, createdAt: Self.now) }
        let retired = RatchetRetention.retiredLocalEpochs(dead + live, highestPeAcked: 0, now: Self.now)
        // Twenty-three held, sixteen kept: the seven minted earliest go, the dead era's lowest numbers here.
        #expect(Set(retired) == Set(47...53))
    }

    @Test func epochsMintedInOneMillisecondRankByNumber() {
        let tied = (1...5).map { (epoch: $0, createdAt: Self.now - 48 * Self.hour) }
        #expect(Set(RatchetRetention.retiredLocalEpochs(tied, highestPeAcked: 5, now: Self.now)) == [1, 2], "3 to 5 are the newest three")
    }

    private func stamp(_ peer: NodeId, epoch: Int, index: Int, rootTag: Int64 = 0, createdAt: Int64) -> RatchetSkippedKeyStamp {
        RatchetSkippedKeyStamp(peer: peer, epoch: epoch, index: index, rootTag: rootTag, createdAt: createdAt)
    }
}
