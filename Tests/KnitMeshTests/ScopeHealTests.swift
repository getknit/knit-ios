import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The heal loop's rules one at a time (`ScopeSyncTest.kt` at knit-next `0832b8462`, the text cases, and P3a's and P3b's
/// reviews): a listing refused whole past its bounds, a push the spool's `maxRecord` cannot carry, per-blob refusals
/// stepped over, `rate` waited out for at most 5 s, parks only on `quota` and `pow`, stamps mined on demand and cancelled
/// with their scope, batches halved after an unscoped `malformed`, an unreadable custody, the byte budget, and a relay
/// faulted for serving garbage.
@Suite struct ScopeHealTests {
    private typealias Fixture = ScopeFixture
    private let scope = ScopeFixture.scope(for: ScopeFixture.alice).id

    // MARK: Listings

    @Test func aListingPastFiveHundredTwelveLiveIdsIsRefusedWhole() throws {
        var bench = HealBench()
        bench.round([])
        let list = try #require(bench.last("list"))
        bench.receive(bench.listing(list, live: (0...ScopeHeal.maxListedIds).map(SpoolSessionFixture.numbered)))
        #expect(bench.heal.counts.overlongListings == 1)
        #expect(bench.pulledIds().isEmpty)
    }

    @Test func aListingPastTheTombstoneBoundIsRefusedWholeAndOneInsideIsWorked() throws {
        var bench = HealBench()
        bench.round([])
        let list = try #require(bench.last("list"))
        let tombstones = (0...ScopeHeal.maxListedTombstones).map(SpoolSessionFixture.numbered)
        bench.receive(bench.listing(list, live: [SpoolSessionFixture.id(3)], tombstones: tombstones))
        #expect(bench.heal.counts.overlongListings == 1 && bench.pulledIds().isEmpty)
        #expect(ScopeHeal.maxListedTombstones == 1024, "max(2 × 400, 1024) over our declared maxFrames")

        var inside = HealBench()
        inside.round([])
        let again = try #require(inside.last("list"))
        let live = (0..<ScopeHeal.maxListedIds).map(SpoolSessionFixture.numbered)
        inside.receive(inside.listing(again, live: live, tombstones: Array(tombstones.dropLast())))
        #expect(inside.heal.counts.overlongListings == 0)
        #expect(inside.pulledIds().count == FakeSpool.defaultLimits.maxPull, "the first batch, at the spool's maxPull")
    }

    @Test func aListingThatNeverCameMarksTheScopeOnlyWhileConnected() throws {
        var bench = HealBench()
        bench.round([])
        _ = try #require(bench.last("list"))
        bench.session.tick(now: SpoolSession.requestMilliseconds)
        bench.flush()
        #expect(bench.heal.dirty.contains(scope))

        var closed = HealBench()
        closed.round([])
        closed.session.socketClosed()
        closed.flush()
        #expect(!closed.heal.dirty.contains(scope))
    }

    @Test func aScopeLeavingTheTableMidRoundLetsTheRoundGoOn() throws {
        let other = ScopeFixture.scope(for: ScopeFixture.alice, seed: 41)
        var bench = HealBench(scopes: [ScopeFixture.scope(for: ScopeFixture.alice), other])
        bench.round([])
        let first = try #require(bench.last("list"))
        bench.heal.adopt([other])
        bench.receive(bench.listing(first, live: []))
        #expect(bench.heal.nextDeadline(sessionReady: true) == .min, "the round asks to be moved on")
        bench.heal.tick(session: &bench.session, now: bench.now)
        bench.flush()
        guard case .list(let next)? = bench.sent.last else {
            Issue.record("the round lists the scope still in the table")
            return
        }
        #expect(SpoolID(next.scope) == other.id)
        #expect(bench.heal.state(scope) == nil)
    }

    @Test func aPullInFlightForAScopeThatLeavesGivesBackItsReservation() throws {
        var bench = HealBench()
        bench.round([])
        bench.receive(bench.listing(try #require(bench.last("list")), live: [SpoolSessionFixture.id(3), SpoolSessionFixture.id(4)]))
        _ = try #require(bench.last("pull"))
        #expect(bench.heal.intake.bytes == 2 * ScopeFrames.maxBlob)
        bench.heal.adopt([])
        #expect(bench.heal.intake.bytes == 0)
    }

    // MARK: Pushes

    @Test func perBlobRefusalsAreSteppedOverAndMakeTheBlobUnpushable() throws {
        var bench = HealBench()
        let first = Fixture.dm(1)
        let second = Fixture.dm(2)
        bench.round([first, second])
        bench.receive(bench.listing(try #require(bench.last("list")), live: []))
        let refused = try #require(bench.last("push"))
        bench.receive(SpoolSessionFixture.err(SpoolErrorCode.tombstoned, request: refused, scope: scope.bytes))
        let stored = try #require(bench.last("push"))
        #expect(stored != refused)
        bench.receive(SpoolSessionFixture.ok(stored))
        let pushed = bench.pushedIds()
        #expect(pushed.count == 2)
        let sets = try #require(bench.heal.state(scope))
        #expect(sets.unpushable.contains(pushed[0]) && !sets.unpushable.contains(pushed[1]), "a pushable id never goes in")
        #expect(bench.heal.dirty.contains(scope))
        // The stored push folded itself into the anchor, so the re-anchor over the listed digest did not write.
        #expect(bench.session.anchor(scope)?.digest == 7 ^ ScopeCrypto.fnv64(pushed[1].bytes))
    }

    @Test func anyOtherPushRefusalEndsTheScopesPushesAndParksNothing() throws {
        var bench = HealBench()
        bench.round([Fixture.dm(1), Fixture.dm(2)])
        bench.receive(bench.listing(try #require(bench.last("list")), live: []))
        let push = try #require(bench.last("push"))
        bench.receive(SpoolSessionFixture.err(SpoolErrorCode.quota, request: push, scope: scope.bytes))
        #expect(bench.pushedIds().count == 1)
        #expect(!bench.heal.isParked(scope, now: bench.now.monotonic))
        #expect(bench.heal.round == nil)
    }

    @Test func aRateRefusalWaitsAtMostFiveSecondsThenGoesOnToTheNext() throws {
        var bench = HealBench()
        bench.round([Fixture.dm(1), Fixture.dm(2)])
        bench.receive(bench.listing(try #require(bench.last("list")), live: []))
        let rated = try #require(bench.last("push"))
        bench.receive(SpoolSessionFixture.err(SpoolErrorCode.rate, request: rated, scope: scope.bytes, retryMs: 600_000))
        #expect(bench.pushedIds().count == 1)
        #expect(bench.heal.nextDeadline(sessionReady: true) == SpoolSession.maxRateWaitMilliseconds)
        bench.now = SpoolNow(
            monotonic: SpoolSession.maxRateWaitMilliseconds, wall: ScopeFixture.wall + SpoolSession.maxRateWaitMilliseconds)
        bench.heal.tick(session: &bench.session, now: bench.now)
        bench.flush()
        let next = try #require(bench.last("push"))
        #expect(next != rated && bench.pushedIds().count == 2)
        #expect(bench.heal.state(scope)?.unpushable.isEmpty == true, "a rate refusal is no refusal of the blob")
    }

    @Test func aPushTheSpoolsMaxRecordCannotCarryIsUnpushableSoTheScopeStopsListing() {
        let limits = SpoolLimits(maxBlob: 65_536, maxRecord: 1024, maxScopes: 8, maxPull: 8, maxFramesCap: 400, maxTtlMs: 604_800_000)
        var lab = HealLab([Fixture.alice], spool: FakeSpool(limits: limits, now: Fixture.wall))
        let big = Fixture.dm(1, padding: 2000)
        lab.members[0].hold([big])
        lab.run(3)
        #expect(lab.members[0].pushes.isEmpty)
        #expect(lab.members[0].heal.state(scope)?.unpushable.contains(Fixture.sealed(big).id) == true)
        lab.members[0].forgetSent()
        lab.advance(by: ScopeHeal.tickMilliseconds)
        #expect(lab.members[0].lists == 0)
    }

    // MARK: Lapsed reasons, deadlines, settlements and printing

    @Test func aShedScopeTakesBackEveryPushableHeldFrameOnce() {
        let spool = FakeSpool(
            limits: SpoolLimits(maxBlob: 65_536, maxRecord: 66_048, maxScopes: 64, maxPull: 64, maxFramesCap: 2, maxTtlMs: 604_800_000),
            now: ScopeFixture.wall)
        var lab = HealLab([ScopeFixture.alice], spool: spool)
        let alice = lab.members[0]
        let frames = (1...3).map { ScopeFixture.dm($0, from: ScopeFixture.bob, to: ScopeFixture.alice) }
        alice.hold(frames)
        lab.run(4)
        #expect(alice.heal.state(scope)?.unpushable.count == 1, "one held frame tombstoned at a two-frame spool")
        alice.forgetSent()
        spool.shed(scope)
        lab.run(4)
        let ids = frames.map { ScopeFixture.sealed($0).id }
        #expect(ids.allSatisfy { id in alice.pushes.count { $0 == id } == 1 }, "each pushable frame re-pushed once")
    }

    @Test func aPushRefusalOutlivesTheListingThatFollows() throws {
        var bench = HealBench()
        let frame = ScopeFixture.dm(1)
        bench.round([frame])
        bench.receive(bench.listing(try #require(bench.last("list")), live: []))
        let push = try #require(bench.last("push"))
        bench.receive(SpoolSessionFixture.err(SpoolErrorCode.tooLarge, request: push, scope: scope.bytes))
        bench.now = SpoolNow(monotonic: 60_000, wall: ScopeFixture.wall + 60_000)
        bench.heal.tick(session: &bench.session, now: bench.now)
        bench.receive(SpoolSessionFixture.digest(scope, value: ScopeCrypto.digestBytes(9), count: 1))
        bench.round([frame])
        bench.receive(bench.listing(try #require(bench.last("list")), live: []))
        #expect(bench.pushedIds().count == 1, "too_large stays refused")
    }

    @Test func aDueTimedRoundIsADeadline() {
        var bench = HealBench(anchor: 0)
        bench.round([])
        #expect(bench.heal.round == nil)
        bench.now = SpoolNow(monotonic: ScopeHeal.tickMilliseconds, wall: ScopeFixture.wall + ScopeHeal.tickMilliseconds)
        bench.heal.tick(session: &bench.session, now: bench.now)
        #expect(bench.heal.timedDue)
        let deadline = bench.heal.nextDeadline(sessionReady: true)
        #expect(deadline.map { $0 <= bench.now.monotonic } == true)
    }

    @Test func aCandidateTheEngineCouldNotTakeIsOnlyReleased() throws {
        let frame = ScopeFixture.dm(1, from: ScopeFixture.bob, to: ScopeFixture.alice)
        let sealed = ScopeFixture.sealed(frame)
        var bench = HealBench(anchor: HealLab.fold([sealed.id]))
        bench.round([])
        bench.receive(bench.listing(try #require(bench.last("list")), live: [sealed.id]))
        let pull = try #require(bench.last("pull"))
        bench.receive(SpoolSessionFixture.blob(sealed.id, scope: scope, data: sealed.blob))
        let candidate = try #require(bench.candidates.first)
        bench.heal.settle(candidate, .notTaken, session: &bench.session, now: bench.now)
        bench.receive(SpoolSessionFixture.ok(pull))
        #expect(bench.heal.state(scope)?.invalid.isEmpty == true && bench.heal.state(scope)?.accounted.isEmpty == true)
        #expect(bench.session.claimCount(scope) == 0)
        #expect(bench.heal.intake.failed == 0)
    }

    @Test func nothingTheHealHoldsPrintsANodeIdAWholeScopeIdOrABlobsBytes() throws {
        let frame = ScopeFixture.dm(1, from: ScopeFixture.bob, to: ScopeFixture.alice)
        let sealed = ScopeFixture.sealed(frame)
        var bench = HealBench(anchor: HealLab.fold([sealed.id]))
        bench.round([ScopeFixture.dm(2)])
        bench.receive(bench.listing(try #require(bench.last("list")), live: [sealed.id]))
        bench.receive(SpoolSessionFixture.blob(sealed.id, scope: scope, data: sealed.blob))
        let candidate = try #require(bench.candidates.first)
        let verified = try #require(candidate.verified(by: ScopeFixture.bob.keys.bundle))
        let step = try #require(bench.heal.step)
        let round = try #require(bench.heal.round)
        let wholeScope = Hex.encode(scope.bytes)
        let secrets = [
            ScopeFixture.alice.nodeId.string, ScopeFixture.bob.nodeId.string, wholeScope, Hex.encode(Array(sealed.blob.prefix(16))),
        ]
        func printed(_ value: Any) -> String {
            var dumped = ""
            dump(value, to: &dumped)
            return "\(value) \(String(reflecting: value)) \(dumped)"
        }
        for text in [printed(bench.heal), printed(step), printed(round), printed(candidate), printed(verified)] {
            #expect(!secrets.contains { text.contains($0) }, "\(text)")
            #expect(!text.contains(frame.envelope.id))
        }
    }
}
