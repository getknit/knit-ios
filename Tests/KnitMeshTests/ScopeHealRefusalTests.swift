import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The heal loop's refusals and limits (`ScopeSyncTest.kt` at knit-next `0832b8462`, and P3a's and P3b's reviews): parks
/// only on `quota` and `pow`, stamps mined on demand and cancelled with their scope, batches halved after an unscoped
/// `malformed`, an unreadable custody, the hour's byte budget, and a relay faulted for serving garbage.
@Suite struct ScopeHealRefusalTests {
    private typealias Fixture = ScopeFixture
    private let scope = ScopeFixture.scope(for: ScopeFixture.alice).id

    // MARK: Refusals, parks and stamps

    @Test func aQuotaRefusalOfASubParksTheScopeForTheClampedPark() {
        let spool = FakeSpool(now: Fixture.wall)
        spool.refuseSub(scope, code: SpoolErrorCode.quota, retryMs: 10)
        var lab = HealLab([Fixture.alice], spool: spool)
        let alice = lab.members[0]
        #expect(alice.heal.isParked(scope, now: 0))
        lab.run(4)
        #expect(alice.subs.count == 1, "parked, not asked again every tick")
        lab.advance(by: SpoolSession.minParkMilliseconds)
        lab.run(1)
        #expect(alice.subs.count == 2 && alice.anchor(scope) != nil)
    }

    @Test func aPowDemandIsMinedAndSentAtOnceWithNoPark() {
        let spool = FakeSpool(powBits: 8, now: Fixture.wall)
        let lab = HealLab([Fixture.alice], spool: spool)
        let alice = lab.members[0]
        #expect(alice.subs.count == 2)
        #expect(alice.subs.first?.subs.first?.pow == nil && alice.subs.last?.subs.first?.pow != nil)
        #expect(alice.anchor(scope) != nil && !alice.heal.isParked(scope, now: 0))
    }

    @Test func aRefusedStampParksTheScope() throws {
        let spool = FakeSpool(powBits: 8, now: Fixture.wall)
        let alice = HealMember(
            Fixture.alice,
            spool: spool,
            scopes: [Fixture.scope(for: Fixture.alice)],
            at: SpoolNow(monotonic: 0, wall: Fixture.wall),
            minesStamps: false
        )
        let request = try #require(alice.pendingMining.first)
        #expect(request.scope == scope && request.bits == 8 && request.relay == SpoolRelayHandle(number: 1))
        spool.refuseSub(scope, code: SpoolErrorCode.pow)
        alice.mine(request)
        #expect(alice.subs.last?.subs.first?.pow != nil)
        #expect(alice.heal.isParked(scope, now: 0))
    }

    @Test func aScopeLeavingTheTableCancelsItsMiningAndDropsItsState() throws {
        let spool = FakeSpool(powBits: 8, now: Fixture.wall)
        let alice = HealMember(
            Fixture.alice,
            spool: spool,
            scopes: [Fixture.scope(for: Fixture.alice)],
            at: SpoolNow(monotonic: 0, wall: Fixture.wall),
            minesStamps: false
        )
        let request = try #require(alice.pendingMining.first)
        alice.heal.adopt([])
        alice.pump()
        #expect(alice.cancelledMining == [request])
        #expect(alice.heal.state(scope) == nil)
        alice.mine(request)
        #expect(alice.subs.count == 1, "a stamp for a scope that left subscribes nothing")
    }

    @Test func anUnscopedMalformedHalvesTheBatchUntilEveryScopeAnchors() {
        let spool = FakeSpool(now: Fixture.wall)
        spool.subBatchLimit = 2
        let scopes = (0..<8).map { Fixture.scope(for: Fixture.alice, seed: 100 + $0) }
        var lab = HealLab([Fixture.alice], scopes: { _ in scopes }, spool: spool)
        lab.run(4)
        let alice = lab.members[0]
        #expect(scopes.allSatisfy { alice.anchor($0.id) != nil })
        #expect(alice.heal.subBatch == 2)
        #expect(alice.subs.map(\.subs.count) == [8, 4, 4, 2, 2, 2, 2])
    }

    // MARK: Custody, the budget and garbage

    @Test func anUnreadableCustodySkipsTheRoundAndNeverReadsAsEmpty() {
        var lab = HealLab([Fixture.alice])
        var other = RawMember(lab.spool)
        other.push(Fixture.dm(9, from: Fixture.bob, to: Fixture.alice))
        let alice = lab.members[0]
        _ = lab.spool.take(alice.connection)
        alice.custodyUnreadable = true
        alice.hold([Fixture.dm(1)])
        lab.run(3)
        #expect(alice.lists == 0 && alice.pushes.isEmpty && alice.pulls.isEmpty)
        #expect(alice.heal.counts.unreadableRounds > 0)
        alice.custodyUnreadable = false
        lab.run(2)
        #expect(alice.pushes.count == 1 && alice.pulls.count == 1)
    }

    @Test func pullsWaitWhileTheHourCannotCarryTheirWorstCase() {
        var lab = HealLab([Fixture.alice])
        var other = RawMember(lab.spool)
        let alice = lab.members[0]
        let frame = Fixture.dm(1, from: Fixture.bob, to: Fixture.alice)
        other.push(frame)
        _ = lab.spool.take(alice.connection)
        lab.spool.inject(
            SpoolSessionFixture.digest(scope, value: ScopeCrypto.digestBytes(HealLab.fold([Fixture.sealed(frame).id])), count: 1),
            into: alice.connection)
        alice.pump()
        alice.heal.intake.charge(bytes: SpoolIntake.maxPulledBytes - ScopeFrames.maxBlob + 1, now: 0)
        lab.run(2)
        #expect(alice.pulls.isEmpty && alice.heal.counts.budgetDeferred == 1)
        lab.advance(by: SpoolIntake.windowMilliseconds)
        #expect(alice.pulls.count == 1)
        #expect(alice.heal.intake.bytes == Fixture.sealed(frame).blob.count, "the worst case's unused part came back")
    }

    @Test func anHourOfOversizeServesUnderFreshIdsCostsTheBudgetAndOneBatch() {
        var lab = HealLab([Fixture.alice])
        var other = RawMember(lab.spool)
        let alice = lab.members[0]
        // One blob the spool really holds, so the digests disagree on every connection.
        other.push(Fixture.dm(1, from: Fixture.bob, to: Fixture.alice))
        _ = lab.spool.take(alice.connection)
        let size = 70_000
        lab.spool.freshIdsPerListing = 64
        lab.spool.oversizeServes = size
        lab.spool.inject(SpoolSessionFixture.digest(scope, value: ScopeCrypto.digestBytes(1), count: 1), into: alice.connection)
        alice.pump()
        var faultsSeen = 0
        for _ in 0..<(SpoolIntake.windowMilliseconds / ScopeHeal.healFloorMilliseconds - 1) {
            lab.advance(by: ScopeHeal.healFloorMilliseconds)
            if !alice.session.isReady {
                faultsSeen += 1
                #expect(alice.heal.intake.bytes > 0, "a fault leaves the hour's bytes standing")
                alice.reconnect()
            }
        }
        #expect(faultsSeen > 0 && alice.heal.counts.faults == faultsSeen)
        #expect(lab.spool.servedBytes > 0)
        #expect(lab.spool.servedBytes <= SpoolIntake.maxPulledBytes + FakeSpool.defaultLimits.maxPull * size)
    }

    @Test func aRelayWhoseServesDoNotHashToTheirIdsIsFaulted() {
        var lab = HealLab([Fixture.alice])
        var other = RawMember(lab.spool)
        let alice = lab.members[0]
        let frames = (0..<40).map { Fixture.dm($0, from: Fixture.bob, to: Fixture.alice) }
        for frame in frames {
            other.push(frame)
        }
        _ = lab.spool.take(alice.connection)
        lab.spool.garblesServes = true
        lab.spool.inject(SpoolSessionFixture.digest(scope, value: ScopeCrypto.digestBytes(1), count: 40), into: alice.connection)
        alice.pump()
        lab.run(1)
        #expect(alice.heal.counts.faults == 1)
        #expect(alice.session.fault == .unopenable && !alice.session.isReady)
        #expect(alice.heal.state(scope)?.invalid.count == SpoolIntake.faultAfterFailures)
        #expect(alice.delivered.isEmpty)
    }

    @Test func blobsAMemberSealedWithBadSignaturesAreQuarantinedAndTheRelayIsNotBlamed() throws {
        var lab = HealLab([Fixture.alice])
        var other = RawMember(lab.spool)
        let alice = lab.members[0]
        for number in 0..<40 {
            var forged = Fixture.dm(number, from: Fixture.bob, to: Fixture.alice)
            forged.wire.sig = try Fixture.carol.keys.signature(for: forged.wire.signed)
            other.push(forged)
        }
        _ = lab.spool.take(alice.connection)
        lab.spool.inject(SpoolSessionFixture.digest(scope, value: ScopeCrypto.digestBytes(1), count: 40), into: alice.connection)
        alice.pump()
        lab.run(1)
        #expect(alice.heal.counts.faults == 0 && alice.session.isReady)
        #expect(alice.heal.state(scope)?.invalid.count == 40)
        #expect(alice.unopenable == 40)
    }

    @Test func aRelayRefusingEveryStampCostsAtMostTheDaysStampsPerScope() {
        let spool = FakeSpool(powBits: 8, now: Fixture.wall)
        spool.refusesEveryPushPow = true
        var lab = HealLab([Fixture.alice], spool: spool)
        let alice = lab.members[0]
        alice.hold([Fixture.dm(1)])
        lab.run(Int(SpoolIntake.windowMilliseconds / ScopeHeal.healFloorMilliseconds))
        #expect(alice.mineRequests.count { $0.scope == scope } <= ScopeHeal.maxStampsPerDay)
        #expect(alice.heal.counts.stampsCapped >= 1)
        #expect(alice.heal.isParked(scope, now: lab.now.monotonic))
    }

    @Test func eachSessionHoldsItsSubsToItsOwnSpoolsMaxScopesInTheTablesOrder() {
        let limits = SpoolLimits(maxBlob: 65_536, maxRecord: 66_048, maxScopes: 2, maxPull: 64, maxFramesCap: 400, maxTtlMs: 604_800_000)
        let scopes = [
            Fixture.scope(for: Fixture.alice, seed: 100), Fixture.scope(for: Fixture.alice, seed: 101),
            Fixture.scope(for: Fixture.alice, retiring: true, seed: 102),
        ]
        var lab = HealLab([Fixture.alice], scopes: { _ in scopes }, spool: FakeSpool(limits: limits, now: Fixture.wall))
        lab.run(2)
        let alice = lab.members[0]
        #expect(alice.anchor(scopes[0].id) != nil && alice.anchor(scopes[1].id) != nil)
        #expect(alice.anchor(scopes[2].id) == nil && alice.heal.state(scopes[2].id) != nil, "out of this spool, kept in the table")
        // A later pass finds no room for it and sends nothing.
        let sent = alice.subs.count
        alice.heal.adopt(scopes)
        lab.run(2)
        #expect(alice.subs.count == sent)
    }

    @Test(arguments: [0, 1024])
    func aSpoolClaimingASmallMaxBlobIsPricedAtOursAndTheHourHolds(maxBlob: Int) {
        let limits = SpoolLimits(maxBlob: maxBlob, maxRecord: 66_048, maxScopes: 64, maxPull: 64, maxFramesCap: 400, maxTtlMs: 604_800_000)
        let spool = FakeSpool(limits: limits, now: Fixture.wall)
        var lab = HealLab([Fixture.alice], spool: spool)
        let alice = lab.members[0]
        spool.freshJunkPerListing = 64
        spool.inject(SpoolSessionFixture.digest(scope, value: ScopeCrypto.digestBytes(1), count: 1), into: alice.connection)
        alice.pump()
        for _ in 0..<(SpoolIntake.windowMilliseconds / ScopeHeal.healFloorMilliseconds - 1) {
            lab.advance(by: ScopeHeal.healFloorMilliseconds)
            if !alice.session.isReady {
                alice.reconnect()
            }
        }
        #expect(spool.servedBytes > SpoolIntake.maxPulledBytes / 2)
        #expect(spool.servedBytes <= SpoolIntake.maxPulledBytes + FakeSpool.defaultLimits.maxPull * ScopeFrames.maxBlob)
        #expect(alice.heal.counts.budgetDeferred > 0)
        #expect(alice.heal.counts.faults == 0, "junk that hashes true is quarantined, never the relay's fault")
    }

    /// An over-budget answer parks the scope for the answer's park and costs none of the day's allowance; the scope asks
    /// again when the park ends (P4b2).
    @Test func anOverBudgetAnswerParksForItsParkAndCostsNoneOfTheDaysAllowance() throws {
        var lab = HealLab([Fixture.alice], spool: FakeSpool(powBits: 8, now: Fixture.wall), manualMiner: Fixture.alice)
        let alice = lab.members[0]
        lab.run(2)
        #expect(alice.mineRequests.count == 1, "nothing asked again while a search is in flight")
        for attempt in 1...2 {
            let request = try #require(alice.pendingMining.first, "attempt \(attempt)")
            alice.failMining(request)
            let parkedUntil = try #require(alice.heal.state(scope)?.parkedUntil)
            #expect(parkedUntil <= lab.now.monotonic + SpoolSession.minParkMilliseconds, "the answer's park, never until midnight")
            lab.advance(by: SpoolSession.minParkMilliseconds)
            lab.run(1)
        }
        #expect(alice.mineRequests.count == 3, "asked again after each park")
        #expect(alice.heal.counts.stampsCapped == 0)
        #expect(alice.heal.state(scope)?.minedToday == 0)
    }

    /// An exhausted answer settles the (scope, day, bits) for the day: the scope parks until the next UTC day after the
    /// request's, counted, and costs none of the allowance (P4b2).
    @Test func anExhaustedAnswerParksUntilTheNextDay() throws {
        var lab = HealLab([Fixture.alice], spool: FakeSpool(powBits: 8, now: Fixture.wall), manualMiner: Fixture.alice)
        let alice = lab.members[0]
        lab.run(2)
        let request = try #require(alice.pendingMining.first)
        let parks = alice.heal.counts.parks
        alice.failMining(request, with: .exhausted)
        let parkedUntil = try #require(alice.heal.state(scope)?.parkedUntil)
        let nextDay = (request.day + 1) * SpoolPow.dayMilliseconds
        #expect(parkedUntil == lab.now.monotonic + max(nextDay - lab.now.wall, SpoolSession.minParkMilliseconds))
        #expect(alice.heal.counts.parks == parks + 1 && alice.heal.state(scope)?.minedToday == 0)
        lab.run(4)
        #expect(alice.mineRequests.count == 1, "nothing asked before the day rolls")
    }
}
