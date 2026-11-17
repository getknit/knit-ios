import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The heal loop's edges, one rule each: a round that is already running, an answer for a step that left, a pull the
/// spool refused, a `rate` wait cut short by the scope's own refusal, a lapsed `sub`, inputs for a scope that left the
/// table, the deadlines, and the timer before any connection.
@Suite struct ScopeHealEdgeTests {
    private typealias Fixture = ScopeFixture
    private let scope = ScopeFixture.scope(for: ScopeFixture.alice).id

    private func lists(_ bench: HealBench) -> Int {
        bench.sent.count { if case .list = $0 { true } else { false } }
    }

    private func subs(_ bench: HealBench) -> Int {
        bench.sent.count { if case .sub = $0 { true } else { false } }
    }

    @Test func aSpoolThatAdvertisedNoLimitsIsPulledFromAtOursAndPushedTo() throws {
        var bench = HealBench(limits: nil)
        bench.round([Fixture.dm(1)])
        let live = (0..<(ScopeHeal.defaultMaxPull + 6)).map(SpoolSessionFixture.numbered)
        bench.receive(bench.listing(try #require(bench.last("list")), live: live))
        #expect(bench.pulledIds().count == ScopeHeal.defaultMaxPull, "a pull names the default 64 ids")
        bench.receive(SpoolSessionFixture.ok(try #require(bench.last("pull")), missing: Array(live.prefix(ScopeHeal.defaultMaxPull))))
        bench.receive(SpoolSessionFixture.ok(try #require(bench.last("pull")), missing: Array(live.suffix(6))))
        #expect(bench.pushedIds() == [Fixture.sealed(Fixture.dm(1)).id], "within our own maxBlob")
    }

    @Test func aRoundAlreadyRunningStartsNoOther() {
        var bench = HealBench()
        bench.round([])
        #expect(!bench.heal.wantsRound(sessionReady: true, now: bench.now))
        bench.round([])
        #expect(lists(bench) == 1)
    }

    @Test func anAnswerForAStepThatLeftTheTableAnswersNothing() throws {
        let other = Fixture.scope(for: Fixture.alice, seed: 41)
        var bench = HealBench(scopes: [Fixture.scope(for: Fixture.alice), other])
        bench.round([])
        let first = try #require(bench.last("list"))
        bench.heal.adopt([other])
        bench.heal.tick(session: &bench.session, now: bench.now)
        bench.flush()
        let second = try #require(bench.last("list"))
        #expect(second != first)
        bench.receive(bench.listing(first, live: [SpoolSessionFixture.id(3)]))
        guard case .listing(let waiting)? = bench.heal.step?.phase else {
            Issue.record("the remaining scope's step still waits on its listing")
            return
        }
        #expect(waiting == second && bench.heal.step?.scope.id == other.id)
        #expect(bench.pulledIds().isEmpty)
    }

    @Test func aPullTheSpoolRefusedEndsThePullingAndThePushesStillRun() throws {
        let limits = SpoolLimits(maxBlob: 65_536, maxRecord: 66_048, maxScopes: 8, maxPull: 1, maxFramesCap: 400, maxTtlMs: 604_800_000)
        var bench = HealBench(limits: limits)
        bench.round([Fixture.dm(1)])
        bench.receive(bench.listing(try #require(bench.last("list")), live: [SpoolSessionFixture.id(3), SpoolSessionFixture.id(4)]))
        let pull = try #require(bench.last("pull"))
        bench.receive(SpoolSessionFixture.err(SpoolErrorCode.internal, request: pull, scope: scope.bytes))
        #expect(bench.pulledIds() == [SpoolSessionFixture.id(3)], "the second batch is never sent")
        #expect(bench.pushedIds() == [Fixture.sealed(Fixture.dm(1)).id])
        #expect(bench.heal.intake.bytes == 0, "the refused pull's worst case came back")
    }

    @Test func aRateWaitTheScopesRefusalCutsShortPushesNothingMore() throws {
        var bench = HealBench()
        bench.round([Fixture.dm(1), Fixture.dm(2)])
        bench.receive(bench.listing(try #require(bench.last("list")), live: []))
        let rated = try #require(bench.last("push"))
        bench.receive(SpoolSessionFixture.err(SpoolErrorCode.rate, request: rated, scope: scope.bytes, retryMs: 1000))
        bench.receive(SpoolSessionFixture.err(SpoolErrorCode.quota, scope: scope.bytes))
        #expect(bench.heal.isParked(scope, now: bench.now.monotonic))
        bench.now = SpoolNow(monotonic: 1000, wall: Fixture.wall + 1000)
        bench.heal.tick(session: &bench.session, now: bench.now)
        bench.flush()
        #expect(bench.pushedIds().count == 1, "no push to a scope the session no longer holds")
        #expect(bench.heal.state(scope)?.unpushable.isEmpty == true, "and nothing marked unpushable for it")
        #expect(bench.heal.round == nil)
    }

    @Test func aLapsedSubIsSentAgainAtTheNextPass() {
        var bench = HealBench(anchor: nil)
        #expect(subs(bench) == 1)
        bench.session.tick(now: SpoolSession.requestMilliseconds)
        bench.flush()
        bench.now = SpoolNow(monotonic: SpoolSession.requestMilliseconds, wall: Fixture.wall + SpoolSession.requestMilliseconds)
        bench.heal.tick(session: &bench.session, now: bench.now)
        bench.flush()
        #expect(subs(bench) == 2)
    }

    @Test func aRecordTheSessionDroppedMovesNothing() {
        var bench = HealBench()
        let before = bench.heal.counts
        bench.receive(SpoolSessionFixture.blob(SpoolSessionFixture.id(9), scope: scope))
        #expect(bench.heal.counts == before && bench.candidates.isEmpty)
        #expect(bench.heal.dirty == [scope], "only the anchor's digest marked it")
    }

    @Test func inputsForAScopeThatLeftTheTableTouchNothing() {
        var bench = HealBench()
        let sealed = Fixture.sealed(Fixture.dm(1, from: Fixture.bob, to: Fixture.alice))
        bench.heal.adopt([])
        bench.receive(SpoolSessionFixture.event(sealed.id, scope: scope, data: sealed.blob))
        #expect(bench.candidates.isEmpty && bench.session.claimCount(scope) == 0)
        bench.receive(SpoolSessionFixture.err(SpoolErrorCode.quota, scope: scope.bytes))
        #expect(bench.heal.counts.parks == 0 && bench.heal.state(scope) == nil)
    }

    @Test func aDirtyScopesDeadlineIsItsFloor() {
        var bench = HealBench(anchor: 0)
        bench.round([])
        #expect(lists(bench) == 0)
        bench.heal.markDirty(scope)
        #expect(bench.heal.nextDeadline(sessionReady: true) == ScopeHeal.healFloorMilliseconds)
        #expect(bench.heal.nextDeadline(sessionReady: false) == ScopeHeal.tickMilliseconds, "no round while no session stands")
    }

    @Test func theTickRunsBeforeAnyConnection() {
        var heal = ScopeHeal(relay: SpoolRelayHandle(number: 1), me: Fixture.alice.nodeId)
        heal.adopt([Fixture.scope(for: Fixture.alice)])
        var session = SpoolSession(openedAt: 0)
        heal.tick(session: &session, now: SpoolNow(monotonic: 1000, wall: Fixture.wall))
        #expect(heal.nextDeadline(sessionReady: false) == 1000 + ScopeHeal.tickMilliseconds)
        #expect(session.drain().isEmpty, "nothing is subscribed before the hello")
    }

    @Test func aParkUntilTheDayRollsEndsAtUTCMidnightWithinItsBounds() {
        let day = SpoolPow.utcDay(nowMs: Fixture.wall)
        let midnight = (day + 1) * SpoolPow.dayMilliseconds
        let now = SpoolNow(monotonic: 0, wall: Fixture.wall)
        #expect(ScopeHeal.untilNextDay(day, now: now) == max(midnight - Fixture.wall, SpoolSession.minParkMilliseconds))
        let late = SpoolNow(monotonic: 0, wall: midnight - 1)
        #expect(ScopeHeal.untilNextDay(day, now: late) == SpoolSession.minParkMilliseconds, "never shorter than the shortest park")
        #expect(ScopeHeal.untilNextDay(.max, now: now) == SpoolPow.dayMilliseconds, "a day past the clock's end")
        let farBack = Int64.min / SpoolPow.dayMilliseconds
        #expect(ScopeHeal.untilNextDay(farBack, now: SpoolNow(monotonic: 0, wall: .max)) == SpoolPow.dayMilliseconds)
    }
}

/// The plane's small values: what each prints, how relays order, the table's ids, and the seal cache's order across
/// the compaction of its touch log.
@Suite struct SpoolValuesTests {
    private typealias Fixture = ScopeFixture

    @Test func scopesRequestsAndBlobsPrintPrefixesAlone() throws {
        let scope = Fixture.scope(for: Fixture.alice, retiring: true)
        let whole = Hex.encode(scope.id.bytes)
        #expect(String(reflecting: scope) == "\(scope.id) (retiring)" && Mirror(reflecting: scope).children.isEmpty)
        let request = SpoolMiningRequest(relay: SpoolRelayHandle(number: 2), scope: scope.id, day: 7, bits: 20)
        #expect("\(request)" == "relay 2 \(scope.id) day 7, 20 bits")
        let sealed = Fixture.sealed(Fixture.dm(1))
        #expect("\(sealed)" == "\(sealed.id), \(sealed.blob.count) bytes" && Mirror(reflecting: sealed).children.isEmpty)
        var cache = ScopeSealCache()
        let held = try #require(
            cache.held([Fixture.carried(Fixture.dm(1))], in: Fixture.scope(for: Fixture.alice), me: Fixture.alice.nodeId).first)
        #expect("\(held)" == "\(sealed)" && Mirror(reflecting: held).children.isEmpty)
        for text in ["\(scope)", "\(request)", "\(sealed)", "\(held)"] {
            #expect(!text.contains(whole) && !text.contains(Fixture.bob.nodeId.string))
        }
    }

    @Test func theTableListsItsRelaysInHandleOrderAndItsScopeIds() {
        let scopes = RatchetSessions.DMScopes(peerId: Fixture.bob.nodeId, live: Fixture.keys(), retiring: Fixture.keys(41))
        let relays = [3, 1, 2, 1].map(SpoolRelayHandle.init(number:))
        guard
            case .table(let table) = ScopeTable().updated(
                dmScopes: [scopes], accepted: [Fixture.bob.nodeId], blocked: [], recent: [:], relays: relays)
        else {
            Issue.record("a table")
            return
        }
        #expect(table.relays.map(\.number) == [1, 2, 3])
        #expect(table.ids == [Fixture.scope(for: Fixture.alice).id, Fixture.scope(for: Fixture.alice, seed: 41).id])
    }

    @Test func aCleartextDMOrAnUnsignedFrameRidesNoScope() {
        let cleartext = RelayEnvelope(
            type: .chat,
            id: FrameId.text(for: fixtureBytes(16, seed: 3)),
            senderId: Fixture.alice.nodeId.string,
            sentAt: Fixture.wall,
            recipientId: Fixture.bob.nodeId.string,
            payload: ChatContent(body: "hi").encoded
        )
        #expect(!ScopeFrames.eligible(cleartext, me: Fixture.alice.nodeId, peer: Fixture.bob.nodeId))
        var unsigned = Fixture.carried(Fixture.dm(1))
        unsigned.sig = []
        #expect(ScopeFrames.seal(unsigned, into: Fixture.scope(for: Fixture.alice)) == nil)
        var cache = ScopeSealCache()
        #expect(cache.held([unsigned], in: Fixture.scope(for: Fixture.alice), me: Fixture.alice.nodeId).isEmpty)
    }

    @Test func theSealCacheKeepsItsLeastRecentlyUsedOrderAcrossACompaction() throws {
        var cache = ScopeSealCache()
        let scope = Fixture.scope(for: Fixture.alice)
        let me = Fixture.alice.nodeId
        let kept = Fixture.dm(0)
        let others = (1..<ScopeSealCache.maxEntries).map { Fixture.dm($0) }
        for frame in others {
            _ = cache.held([Fixture.carried(frame)], in: scope, me: me)
        }
        // Enough touches of one frame to compact the log, which must leave it the most recently used.
        for _ in 0...(4 * ScopeSealCache.maxEntries) {
            _ = cache.held([Fixture.carried(kept)], in: scope, me: me)
        }
        _ = cache.held([Fixture.carried(Fixture.dm(5000))], in: scope, me: me)
        #expect(cache.count == ScopeSealCache.maxEntries)
        // A frame under a cached id answers its cached seal; one under an evicted id is sealed afresh.
        let keptAgain = Fixture.carried(Fixture.dm(9000, id: kept.envelope.id))
        let keptSeal = try #require(cache.held([keptAgain], in: scope, me: me).first)
        #expect(keptSeal.id == Fixture.sealed(kept).id, "the frame touched last is still cached")
        let oldestAgain = Fixture.carried(Fixture.dm(9001, id: others[0].envelope.id))
        let oldestSeal = try #require(cache.held([oldestAgain], in: scope, me: me).first)
        #expect(oldestSeal.id != Fixture.sealed(others[0]).id, "the least recently used went")
    }
}
