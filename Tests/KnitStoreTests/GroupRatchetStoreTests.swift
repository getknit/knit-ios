import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The group form's store over every store kind: knit-next's `GroupRatchetRepositoryTest` (at `cbf2a487`) case by case,
/// for row fidelity, `applyOpen`'s delta with the mint-keyed rows and the skipped-key lifecycle, the seed outbox, the
/// retired chain, and the retention sweep that enforces the group's forward-secrecy window. Its other three cases seal
/// through the session layer, and run in KnitMesh's `GroupRatchetSessionsStoreTests` over both kinds. Then what this port
/// adds: an open's writes go with a unit that fails, group ids are their bytes, and both stores evict the same keys at
/// the cap (ADR 2026-10.5sk9).
@Suite struct GroupRatchetStoreTests {
    static let kinds = RepositoryKind.allCases
    static let now: Int64 = 1_700_000_000_000
    static let group = "g-0123456789abcdef01234567"
    static let thirtyDays: Int64 = 30 * 24 * 60 * 60_000

    let sender = fixtureNodeId(1)
    let member = fixtureNodeId(2)

    @Test(arguments: kinds)
    func sendChainRoundTripsAndNewestWins(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        store.commitSend(sendChain(epoch: 1, count: 7), in: Self.group)
        store.commitSend(sendChain(epoch: 2, mintedAt: Self.now + 5), in: Self.group)

        let newest = try #require(store.sendChain(Self.group))
        #expect(newest.epoch == 2)
        #expect(newest.mintedAt == Self.now + 5)
        #expect(store.sendChains(Self.group).map(\.epoch) == [2, 1])

        let older = try #require(store.sendChains(Self.group).last)
        #expect(older.count == 7)
        #expect(older.seed == bytes(1))
        #expect(older == sendChain(epoch: 1, count: 7), "every field comes back")
    }

    @Test(arguments: kinds)
    func aSealAdvanceUpdatesTheSameEpochRow(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        store.commitSend(sendChain(epoch: 1, count: 0), in: Self.group)
        store.commitSend(sendChain(epoch: 1, count: 1), in: Self.group)

        #expect(store.sendChains(Self.group).count == 1)
        #expect(store.sendChain(Self.group)?.count == 1)
    }

    @Test(arguments: kinds)
    func recvChainsComeBackNewestMintFirst(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        store.insertRecvChain(recvChain(mintedAt: Self.now - 10), in: Self.group, from: sender)
        store.insertRecvChain(recvChain(mintedAt: Self.now), in: Self.group, from: sender)

        #expect(store.recvChains(Self.group, from: sender, epoch: 1).map(\.mintedAt) == [Self.now, Self.now - 10])
    }

    @Test(arguments: kinds)
    func applyOpenUpsertsTheChainAndCyclesSkippedKeys(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        store.insertRecvChain(recvChain(), in: Self.group, from: sender)
        let banked = [skippedKey(index: 0, fill: 9), skippedKey(index: 1, fill: 8)]
        store.applyOpen(GroupOpenDelta(recvChain: recvChain(next: 3), skippedInserts: banked), in: Self.group, from: sender, se: 1, n: 2)

        #expect(store.recvChains(Self.group, from: sender, epoch: 1).map(\.next) == [3])
        #expect(store.skippedKeys(Self.group, from: sender, epoch: 1, index: 0).map(\.messageKey) == [bytes(9)])

        // Consuming index 0 deletes the spent key's row and touches nothing else. Kotlin's names the index alone and takes
        // every mint's row there; this port names the mint too (knit-next #177), and `+Port` holds the other mint's row.
        store.applyOpen(GroupOpenDelta(recvChain: nil, consumedSkippedMintedAt: Self.now), in: Self.group, from: sender, se: 1, n: 0)
        #expect(store.skippedKeys(Self.group, from: sender, epoch: 1, index: 0).isEmpty)
        #expect(store.skippedKeys(Self.group, from: sender, epoch: 1, index: 1).count == 1)
    }

    @Test(arguments: kinds)
    func theOutboxTracksSendsAndAcksMonotonically(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        store.markKeySent(Self.group, to: member, epoch: 1, at: Self.now)
        store.markKeySent(Self.group, to: member, epoch: 2, at: Self.now + 1)

        var row = try #require(store.keySend(Self.group, member: member))
        #expect(row.sentEpoch == 2)
        #expect(row.ackedEpoch == 0)

        store.markKeyAcked(Self.group, by: member, epoch: 2, at: Self.now + 2)
        row = try #require(store.keySend(Self.group, member: member))
        #expect(row.ackedEpoch == 2)
        #expect(row.ackedAt == Self.now + 2)

        // A stale (older-epoch) ack never rewinds; an ack with no row is ignored.
        store.markKeyAcked(Self.group, by: member, epoch: 1, at: Self.now + 3)
        #expect(store.keySend(Self.group, member: member)?.ackedEpoch == 2)
        let stranger = fixtureNodeId(9)
        store.markKeyAcked(Self.group, by: stranger, epoch: 9, at: Self.now)
        #expect(store.keySend(Self.group, member: stranger) == nil)

        store.deleteKeySend(Self.group, member: member)
        #expect(store.keySend(Self.group, member: member) == nil)
    }

    @Test(arguments: kinds)
    func purgeGroupDropsEveryTable(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        store.commitSend(sendChain(), in: Self.group)
        store.insertRecvChain(recvChain(), in: Self.group, from: sender)
        store.applyOpen(
            GroupOpenDelta(recvChain: nil, skippedInserts: [skippedKey(index: 0, fill: 0)]), in: Self.group, from: sender, se: 1, n: 0)
        store.markKeySent(Self.group, to: member, epoch: 1, at: Self.now)

        store.purgeGroup(Self.group)

        // The send chain's keys go; its number stays on a retired row (knit-next ADR 2026-10.xgwj).
        #expect(store.sendChain(Self.group)?.isRetired == true)
        #expect(store.sendChains(Self.group).isEmpty)
        #expect(store.recvChains(Self.group, from: sender, epoch: 1).isEmpty)
        #expect(store.skippedKeys(Self.group, from: sender, epoch: 1, index: 0).isEmpty)
        #expect(store.keySend(Self.group, member: member) == nil)
    }

    @Test(arguments: kinds)
    func sweepEnforcesTheRetentionWindows(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        let old = Self.now - GroupRatchetRetention.skippedKeyMilliseconds - 1
        store.insertRecvChain(recvChain(epoch: 1, lastUsedAt: old), in: Self.group, from: sender)
        store.insertRecvChain(recvChain(epoch: 2), in: Self.group, from: sender)
        let keys = [skippedKey(index: 0, fill: 0, epoch: 1, createdAt: old), skippedKey(index: 0, fill: 0, epoch: 2)]
        store.applyOpen(GroupOpenDelta(recvChain: nil, skippedInserts: keys), in: Self.group, from: sender, se: 1, n: 9)

        store.sweep(now: Self.now)

        #expect(store.recvChains(Self.group, from: sender, epoch: 1).isEmpty)
        #expect(store.recvChains(Self.group, from: sender, epoch: 2).count == 1)
        #expect(store.skippedKeys(Self.group, from: sender, epoch: 1, index: 0).isEmpty)
        #expect(store.skippedKeys(Self.group, from: sender, epoch: 2, index: 0).count == 1)
    }

    @Test(arguments: kinds)
    func sweepRetiresSupersededSendChainsButDrainsThePreviousOne(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        store.commitSend(sendChain(epoch: 1, mintedAt: Self.now - 10), in: Self.group)
        store.commitSend(sendChain(epoch: 2, mintedAt: Self.now - 5), in: Self.group)
        store.commitSend(sendChain(epoch: 3, mintedAt: Self.now), in: Self.group)

        // The newest mint is fresh: keep it and the draining previous epoch, drop the rest.
        store.sweep(now: Self.now)
        #expect(store.sendChains(Self.group).map(\.epoch) == [3, 2])

        // Once the newest mint is older than the drain window, only it survives.
        store.sweep(now: Self.now + GroupRatchetRetention.previousSeedMilliseconds)
        #expect(store.sendChains(Self.group).map(\.epoch) == [3])
        #expect(store.sendChain(Self.group) != nil)
    }

    @Test(arguments: kinds)
    func retiringTwiceKeepsTheNumberAndRetiringNothingIsANoOp(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        store.retireSendChains(Self.group)
        #expect(store.sendChain(Self.group) == nil)
        #expect(store.holdings(of: Self.group).sendChains.isEmpty)

        store.commitSend(sendChain(epoch: 4), in: Self.group)
        store.retireSendChains(Self.group)
        store.retireSendChains(Self.group)
        #expect(store.sendChain(Self.group)?.epoch == 4)
        #expect(store.sendChain(Self.group)?.isRetired == true)
    }

    @Test(arguments: kinds)
    func anExhaustedLiveChainIsStillReServed(kind: RepositoryKind) throws {
        // Rule 2 (the count) keeps the seed; only a forced rekey's retired row is filtered out.
        let store = try kind.make().groupRatchet
        store.commitSend(sendChain(epoch: 2, count: GroupRatchetRetention.retiredCount), in: Self.group)
        #expect(store.sendChains(Self.group).map(\.epoch) == [2])
    }

    @Test(arguments: kinds)
    func theSweepKeepsARetiredNewestAndDrainsItAfterTheNextMint(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        store.commitSend(sendChain(epoch: 1, mintedAt: Self.now - GroupRatchetRetention.previousSeedMilliseconds), in: Self.group)
        store.retireSendChains(Self.group)

        // The newest, older than any drain window: it holds the number the next mint must pass.
        store.sweep(now: Self.now)
        #expect(store.sendChain(Self.group)?.epoch == 1)

        store.commitSend(sendChain(epoch: 2, mintedAt: Self.now), in: Self.group)
        store.sweep(now: Self.now + 1)
        #expect(store.holdings(of: Self.group).sendChains.map(\.epoch) == [2, 1])
        #expect(store.sendChains(Self.group).map(\.epoch) == [2])

        store.sweep(now: Self.now + GroupRatchetRetention.previousSeedMilliseconds)
        #expect(store.holdings(of: Self.group).sendChains.map(\.epoch) == [2])
    }

    @Test(arguments: kinds)
    func theSweepNeverDropsALiveNewestChain(kind: RepositoryKind) throws {
        // Long past every window, but live: it is still the sealing epoch and the re-distribution source.
        let store = try kind.make().groupRatchet
        store.commitSend(sendChain(epoch: 5, mintedAt: Self.now), in: Self.group)
        store.sweep(now: Self.now + Self.thirtyDays)
        #expect(store.sendChains(Self.group).map(\.epoch) == [5])

        store.commitSend(sendChain(epoch: 6, mintedAt: Self.now, count: GroupRatchetRetention.retiredCount), in: Self.group)
        store.sweep(now: Self.now + Self.thirtyDays)
        #expect(store.sendChains(Self.group).map(\.epoch) == [6], "an exhausted chain is not a retired one")
    }
}

// The fixtures, apart from the suite only to keep its body inside the lint's length.
extension GroupRatchetStoreTests {
    func bytes(_ fill: UInt8) -> [UInt8] {
        [UInt8](repeating: fill, count: 32)
    }

    func sendChain(epoch: Int = 1, mintedAt: Int64 = Self.now, count: Int = 0) -> GroupSendChainRecord {
        GroupSendChainRecord(epoch: epoch, seed: bytes(1), chainKey: bytes(UInt8(2 + epoch)), count: count, mintedAt: mintedAt)
    }

    func recvChain(epoch: Int = 1, mintedAt: Int64 = Self.now, next: Int = 0, lastUsedAt: Int64 = Self.now) -> GroupRecvChainRecord {
        GroupRecvChainRecord(epoch: epoch, mintedAt: mintedAt, chainKey: bytes(4), next: next, lastUsedAt: lastUsedAt)
    }

    func skippedKey(
        index: Int,
        fill: UInt8,
        epoch: Int = 1,
        mintedAt: Int64 = Self.now,
        createdAt: Int64 = Self.now
    ) -> GroupSkippedKeyRecord {
        GroupSkippedKeyRecord(epoch: epoch, mintedAt: mintedAt, index: index, messageKey: bytes(fill), createdAt: createdAt)
    }
}
