import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The group form's retention as pure rules (``GroupRatchetRetention``), the constants and windows of knit-next's
/// `GroupRatchetRepository` (`GroupRatchetRepository.kt:154-236`, at `cbf2a487`) that both stores apply.
@Suite struct GroupRatchetRetentionTests {
    static let now: Int64 = 1_700_000_000_000

    @Test func theWindowsAreAndroidsTwoDaysAndTheCapItsOwnTwoThousand() {
        #expect(GroupRatchetRetention.skippedKeyMilliseconds == 48 * 60 * 60_000)
        #expect(GroupRatchetRetention.receiveChainMilliseconds == 48 * 60 * 60_000)
        #expect(GroupRatchetRetention.previousSeedMilliseconds == 48 * 60 * 60_000)
        #expect(GroupRatchetRetention.maxSkippedKeys == 2000)
        #expect(GroupRatchetRetention.skippedKeyCutoff(now: Self.now) == Self.now - GroupRatchetRetention.skippedKeyMilliseconds)
        #expect(GroupRatchetRetention.receiveChainCutoff(now: Self.now) == Self.now - GroupRatchetRetention.receiveChainMilliseconds)
        #expect(
            GroupRatchetRetention.skippedKeyCutoff(now: Int64.min) == Int64.min &- GroupRatchetRetention.skippedKeyMilliseconds,
            "wraps as a Long")
        #expect(GroupRatchetRetention.skippedKeyExcess(count: 2000) == 0)
        #expect(GroupRatchetRetention.skippedKeyExcess(count: 2003) == 3)
    }

    /// The newest chain always stays; the previous one drains for two days past the newest's mint, and below it nothing
    /// stays (`sweepSendChains`, `:162-181`).
    @Test func theNewestChainStaysAndThePreviousDrainsTwoDaysPastItsMint() {
        let window = GroupRatchetRetention.previousSeedMilliseconds
        #expect(GroupRatchetRetention.lowestKeptEpoch(newest: 5, mintedAt: Self.now, now: Self.now) == 4)
        #expect(GroupRatchetRetention.lowestKeptEpoch(newest: 5, mintedAt: Self.now, now: Self.now + window - 1) == 4)
        #expect(GroupRatchetRetention.lowestKeptEpoch(newest: 5, mintedAt: Self.now, now: Self.now + window) == 5)
        // A clock set back keeps the previous one, as Kotlin's subtraction does.
        #expect(GroupRatchetRetention.lowestKeptEpoch(newest: 1, mintedAt: Self.now, now: Self.now - window) == 0)
    }

    @Test func aRetiredChainKeepsItsNumberAndMintAndNoKeyAtTheCap() {
        let live = GroupSendChainRecord(epoch: 3, seed: [1], chainKey: [2], count: 9, mintedAt: 44)
        let retired = GroupRatchetRetention.retired(live)
        #expect(retired == GroupSendChainRecord(epoch: 3, seed: [], chainKey: [], count: GroupRatchetRetention.retiredCount, mintedAt: 44))
        #expect(retired.isRetired && !live.isRetired)
        let exhausted = GroupSendChainRecord(epoch: 3, seed: [1], chainKey: [2], count: GroupRatchetRetention.retiredCount, mintedAt: 44)
        #expect(!exhausted.isRetired, "the count never says retired: the seed does")
    }

    /// The cap evicts the oldest first, and a tie goes by group bytes, sender, epoch, mint and index, so both stores take
    /// the same keys; under the cap nothing goes.
    @Test func theCapEvictsTheOldestFirstAndBreaksATieByTheWholeKey() {
        let low = fixtureNodeId(1) < fixtureNodeId(2) ? fixtureNodeId(1) : fixtureNodeId(2)
        let high = low == fixtureNodeId(1) ? fixtureNodeId(2) : fixtureNodeId(1)
        func stamp(
            _ group: String,
            _ sender: NodeId,
            epoch: Int = 1,
            mintedAt: Int64 = 0,
            index: Int = 0,
            createdAt: Int64 = 5
        ) -> GroupSkippedKeyStamp {
            GroupSkippedKeyStamp(
                group: ExactKey(group), sender: sender, epoch: epoch, mintedAt: mintedAt, index: index, createdAt: createdAt)
        }
        let ordered = [
            stamp("g-z", high, createdAt: 1),
            stamp("g-a", low),
            stamp("g-a", low, index: 1),
            stamp("g-a", low, mintedAt: 1),
            stamp("g-a", low, epoch: 2),
            stamp("g-a", high),
            stamp("g-b", low),
            stamp("g-ba", low),
        ]
        let held =
            ordered.reversed()
            + (0..<(GroupRatchetRetention.maxSkippedKeys - ordered.count)).map { index in
                stamp("g-z", high, epoch: 9, index: index, createdAt: 6)
            }
        #expect(GroupRatchetRetention.evictedSkippedKeys(Array(held)).isEmpty, "at the cap, nothing goes")
        let over = held + ordered.map { stamp("g-zz", $0.sender, epoch: $0.epoch, mintedAt: $0.mintedAt, index: $0.index, createdAt: 7) }
        #expect(GroupRatchetRetention.evictedSkippedKeys(Array(over)) == ordered)
    }
}
