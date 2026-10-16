import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The three cases of knit-next's `GroupRatchetRepositoryTest` (at `cbf2a487`) that seal through `GroupRatchetSessions`,
/// over both store kinds; the other twelve are KnitStore's `GroupRatchetStoreTests`. Each pins knit-next ADR 2026-10.xgwj:
/// a forced rekey, a leave and a delete retire the send chain, keys gone and number kept, so the next seal mints past
/// it, never a second epoch under a number receivers already hold (#167).
@Suite struct GroupRatchetSessionsStoreTests {
    static let kinds = GroupSessionKind.allCases
    static let group = "g-0123456789abcdef01234567"
    static let now: Int64 = 1_700_000_000_000
    static let thirtyDays: Int64 = 30 * 24 * 60 * 60_000

    let me = fixtureNodeId(1)

    @Test(arguments: kinds)
    func aForcedRekeyRetiresTheChainsAndTheNextSealMintsPastThem(kind: GroupSessionKind) throws {
        let made = try kind.make()
        let sessions = made.sessions(me)
        // An exhausted epoch 1, still draining, so the seal mints epoch 2 over it.
        made.store.commitSend(GroupSendChainRecord(epoch: 1, seed: [1], chainKey: [2], count: 200, mintedAt: Self.now - 10), in: Self.group)
        let firstEpoch = try minted(sessions, now: Self.now)
        #expect(made.store.sendChains(Self.group).map(\.epoch) == [2, 1])

        made.store.retireSendChains(Self.group)

        let retired = try #require(made.store.sendChain(Self.group))
        #expect(retired.epoch == firstEpoch && retired.mintedAt == Self.now && retired.isRetired)
        #expect(retired.seed.count + retired.chainKey.count == 0, "no key byte survives")
        #expect(retired.count == GroupRatchetEngine.maxEpochMessages)
        #expect(made.store.holdings(of: Self.group).sendChains.count == 1, "the draining seed went too")
        #expect(made.store.sendChains(Self.group).isEmpty, "a retired chain is never re-served")
        #expect(sessions.currentSeeds(of: Self.group) == .settled([]))

        #expect(try minted(sessions, now: Self.now + 1) == firstEpoch + 1)
        #expect(made.store.sendChains(Self.group).map(\.epoch) == [firstEpoch + 1])
        #expect(sessions.currentSeeds(of: Self.group).settledValue?.map(\.epoch) == [firstEpoch + 1])
    }

    /// A local leave or delete: the same people put together again are the same group id, so the purge keeps the epoch
    /// number the others hold, and the next mint numbers past it instead of reusing epoch 1.
    @Test(arguments: kinds)
    func aPurgeKeepsAKeylessRetiredRowAndTheNextMintNumbersPastIt(kind: GroupSessionKind) throws {
        let made = try kind.make()
        let sessions = made.sessions(me)
        let epoch = try minted(sessions, now: Self.now)

        made.store.purgeGroup(Self.group)

        let retired = try #require(made.store.sendChain(Self.group))
        #expect(retired.epoch == epoch)
        #expect(retired.seed.count + retired.chainKey.count == 0, "no key byte survives")
        #expect(made.store.sendChains(Self.group).isEmpty)
        #expect(try minted(sessions, now: Self.now + 1) == epoch + 1)
    }

    /// A retired number is never dropped while it is the newest: numbering only rises, but after a wipe. A group left for
    /// good keeps this one key-less row.
    @Test(arguments: kinds)
    func aRetiredNewestRowKeepsItsNumberAndNoKeyForever(kind: GroupSessionKind) throws {
        let made = try kind.make()
        made.store.commitSend(GroupSendChainRecord(epoch: 3, seed: [1], chainKey: [2], count: 0, mintedAt: Self.now), in: Self.group)
        made.store.retireSendChains(Self.group)

        made.store.sweep(now: Self.now + Self.thirtyDays)

        let retired = try #require(made.store.sendChain(Self.group))
        #expect(retired.epoch == 3 && retired.isRetired)
        #expect(retired.seed.count + retired.chainKey.count == 0, "no key byte")
        #expect(made.store.sendChains(Self.group).isEmpty)
        #expect(try minted(made.sessions(me), now: Self.now + Self.thirtyDays) == 4)
    }

    /// The epoch a seal minted, which it must.
    private func minted(_ sessions: GroupRatchetSessions, now: Int64) throws -> Int {
        let answer = sessions.sealGroup(plaintext: Array("x".utf8), aad: Array("a".utf8), in: Self.group, now: now)
        guard case .settled(.sealed(_, let minted?)) = answer else {
            Issue.record("expected a seal that mints, got \(answer)")
            throw GroupRatchetSessionsTests.Unexpected()
        }
        return minted.epoch
    }
}
