import KnitWire
import Testing

@testable import KnitMesh

/// The record layer of one spool connection: knit-next's `SpoolConnectionTest` at `0832b8462`, its text cases one for one.
///
/// Left out with the planes this port does not carry (ADR 2026-11.adrq): Knit Anywhere's five TURN cases (`a spool that
/// never advertised turn…`, `a turncred answers…`, `a refused turnreq…`, `a silent turnreq…`, `a hung-up call's
/// turnreq…`), the attachments' five (`rejects an achunk…`, `drops an achunk…`, `keeps one copy of each index…`, `bounds
/// an achunk…`, `an ahas about another scope…`), and the commons' two (`a hello that advertises a commons…`, `a commons
/// pin past what one listing can carry…`). Casts and sigs have none there.
@Suite struct SpoolSessionTests {
    private typealias Fixture = SpoolSessionFixture
    private let scope = SpoolSessionFixture.scope
    private let other = SpoolSessionFixture.other

    @Test func answersTheSpoolsUnpromptedHelloWithNothingButTheChosenVersion() {
        var session = SpoolSession(openedAt: 0)
        session.receive(Fixture.hello(powBits: 20))
        let outputs = session.drain()

        // Byte-identical to §13's `helloClient` vector: {"t":"hello","v":1} and nothing else.
        #expect(outputs == [.send([0xA2, 0x61, 0x74, 0x65, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x61, 0x76, 0x01]), .event(.connected)])
        #expect(session.isReady)
        #expect(session.powBits == 20)
        #expect(session.limits?.maxPull == 2)
    }

    @Test func closes4002AndNeverSendsAHelloWhenTheVersionsDoNotOverlap() {
        var session = SpoolSession(openedAt: 0)
        session.receive(Fixture.hello(version: 99, minimum: 7))
        let outputs = session.drain()

        #expect(outputs.closes == [SpoolCloseCode.version])
        #expect(outputs.records.isEmpty)
        #expect(outputs.events == [.ended(fault: .version)])
        #expect(!session.isReady)
    }

    @Test func subMarksTheScopeSubscribedAndAScopedErrUnmarksIt() {
        var session = Fixture.ready()
        let subscribed1 = session.subscribe([ScopeSub(scope: scope.bytes, bounds: Fixture.bounds)], now: 0)
        #expect(subscribed1 == [scope])
        #expect(session.isSubscribed(scope))

        // A refusal carries the sub's `q`, which no outstanding request owns: it is the scope's, not silence.
        session.receive(Fixture.err(SpoolErrorCode.pow, request: 99, scope: scope.bytes))
        let events = session.drain().events

        #expect(!session.isSubscribed(scope))
        guard case .scopeRefused(let refused, let refusal) = events.first else {
            Issue.record("expected a refused scope, got \(events)")
            return
        }
        #expect(refused == scope)
        #expect(refusal.code.is(SpoolErrorCode.pow))
    }

    @Test func correlatesConcurrentRequestsByQAndAttributesBlobsToThePullNotAParallelList() throws {
        var session = Fixture.subscribed()
        let listed1 = session.list(scope, now: 0)
        let listQ = try #require(listed1)
        let pulled1 = session.pull(scope, [other, Fixture.id(5)], now: 0)
        let pullQ = try #require(pulled1)
        #expect(pullQ > listQ, "q rises per connection")
        _ = session.drain()

        // A blob carries no q: it lands in the pull though a list for the scope is outstanding.
        session.receive(Fixture.blob(other))
        session.receive(Fixture.ok(pullQ, missing: [Fixture.id(5)]))
        session.receive(Fixture.listing(listQ, live: [other.bytes]))

        #expect(
            session.drain().events == [
                .pulled(request: pullQ, SpoolArrival(scope: scope, blobId: other, data: [7])),
                .answered(request: pullQ, .pulled(missing: [Fixture.id(5)], oversize: [])),
                .answered(request: listQ, .listing(live: [other], tombstones: [])),
            ])
    }

    @Test func aDeadSocketFailsEveryOutstandingRequestInsteadOfHangingTheHealLoop() throws {
        var session = Fixture.subscribed()
        let pushed1 = session.push(scope, blobId: other, data: [1], pow: nil, now: 0)
        let push = try #require(pushed1)
        _ = session.drain()
        session.socketClosed()

        #expect(session.drain().events == [.answered(request: push, .closed), .ended(fault: nil)])
        #expect(!session.isSubscribed(scope))
        #expect(session.nextDeadline == nil)
    }

    @Test func aRequestTheSpoolNeverAnswersTimesOutInsteadOfWedgingTheHealLoop() throws {
        var session = Fixture.subscribed()
        let pushed2 = session.push(scope, blobId: other, data: [1], pow: nil, now: 1000)
        let push = try #require(pushed2)
        _ = session.drain()
        #expect(session.nextDeadline == 31_000)

        session.tick(now: 30_999)
        #expect(session.drain().isEmpty, "still waiting while the spool stays silent")
        session.tick(now: 31_000)
        #expect(session.drain().events == [.answered(request: push, .unanswered)])
    }

    @Test func refusesToEmitARecordLargerThanTheSpoolsAdvertisedMaxRecord() {
        var session = Fixture.subscribed()

        let pushed3 = session.push(scope, blobId: other, data: [UInt8](repeating: 0, count: 8192), pow: nil, now: 0)
        #expect(pushed3 == nil)
        #expect(session.drain().isEmpty, "an oversize record never reaches the wire")
    }

    @Test func ignoresUnknownRecordTypesAndAPostNegotiationHelloRatherThanTearingDown() {
        var session = Fixture.ready()
        session.receive(SpoolErr(code: "x").cbor.replacingType(with: "x-future"))
        session.receive(Fixture.hello(powBits: 30))
        session.receive([0xFF, 0x00])
        let outputs = session.drain()

        #expect(outputs.closes.isEmpty)
        #expect(outputs.records.isEmpty)
        #expect(outputs.events == [.dropped(.unknown(SpoolText("x-future"))), .dropped(.lateHello), .dropped(.undecodable)])
        #expect(session.powBits == 0, "a second hello never renegotiates")
    }

    @Test func dropsABlobThePullNeverAskedForInsteadOfHandingItToTheCaller() throws {
        var session = Fixture.subscribed()
        let pulled2 = session.pull(scope, [other], now: 0)
        let pull = try #require(pulled2)
        _ = session.drain()
        session.receive(Fixture.blob(Fixture.id(9)))
        session.receive(Fixture.ok(pull))

        // Not an answer, and not ours to quarantine either: we never pulled it.
        #expect(
            session.drain() == [
                .event(.dropped(.unsolicited)), .event(.answered(request: pull, .pulled(missing: [], oversize: []))),
            ])
    }

    @Test func aBlobFloodCanNeverOutgrowTheIdListThePullNamed() throws {
        var session = Fixture.subscribed(hello: Fixture.hello(limits: Fixture.greedyLimits))
        let wanted = [Fixture.id(1), Fixture.id(2), Fixture.id(3)]
        let pulled3 = session.pull(scope, wanted, now: 0)
        let pull = try #require(pulled3)
        _ = session.drain()
        for flood in 0..<500 {
            for id in wanted {
                session.receive(Fixture.blob(id))
            }
            session.receive(Fixture.blob(Fixture.id(100 + flood), data: [UInt8](repeating: 0, count: 1024)))
        }
        session.receive(Fixture.ok(pull))

        let pulled = session.drain().events.compactMap { event -> SpoolID? in
            guard case .pulled(_, let arrival) = event else {
                return nil
            }
            return arrival.blobId
        }
        #expect(pulled == wanted, "one slot per named id, and no more")
    }

    @Test func reportsAnOversizeBlobForQuarantineHoweverLargeTheSpoolSaidItsOwnMaxBlobWas() throws {
        // The spool advertises a megabyte; the bound that counts is the one we declared at `sub`.
        var session = Fixture.subscribed(hello: Fixture.hello(limits: Fixture.greedyLimits))
        let pulled4 = session.pull(scope, [other], now: 0)
        let pull = try #require(pulled4)
        _ = session.drain()
        session.receive(Fixture.blob(other, data: [UInt8](repeating: 0, count: SpoolRecordLayer.defaultMaxBlob + 1)))
        session.receive(Fixture.ok(pull))

        // Accounted rather than dropped: the spool still holds it, so without §9.3 the digests diverge for good.
        #expect(session.drain().events == [.answered(request: pull, .pulled(missing: [], oversize: [other]))])
    }

    @Test func keepsABlobExactlyAtTheBoundWeDeclaredAtSub() throws {
        var session = Fixture.subscribed(hello: Fixture.hello(limits: Fixture.greedyLimits))
        let pulled5 = session.pull(scope, [other], now: 0)
        let pull = try #require(pulled5)
        _ = session.drain()
        let data = [UInt8](repeating: 0, count: SpoolRecordLayer.defaultMaxBlob)
        session.receive(Fixture.blob(other, data: data))
        session.receive(Fixture.ok(pull))

        #expect(
            session.drain().events == [
                .pulled(request: pull, SpoolArrival(scope: scope, blobId: other, data: data)),
                .answered(request: pull, .pulled(missing: [], oversize: [])),
            ])
    }

    @Test func attributesABlobToThePullThatNamedItWhenTwoPullsForOneScopeOverlap() throws {
        var session = Fixture.subscribed()
        let pulled6 = session.pull(scope, [Fixture.id(1)], now: 0)
        let first = try #require(pulled6)
        let pulled7 = session.pull(scope, [Fixture.id(2)], now: 0)
        let second = try #require(pulled7)
        _ = session.drain()
        session.receive(Fixture.blob(Fixture.id(2), data: [2]))
        session.receive(Fixture.blob(Fixture.id(1), data: [1]))

        #expect(
            session.drain().events == [
                .pulled(request: second, SpoolArrival(scope: scope, blobId: Fixture.id(2), data: [2])),
                .pulled(request: first, SpoolArrival(scope: scope, blobId: Fixture.id(1), data: [1])),
            ])
    }

    @Test func aTimedOutPullCollectsNothingMoreFromASpoolStillStreamingIntoIt() throws {
        var session = Fixture.subscribed()
        let pulled8 = session.pull(scope, [other], now: 0)
        let pull = try #require(pulled8)
        session.tick(now: 60_000)
        #expect(session.drain().events == [.answered(request: pull, .unanswered)])

        for _ in 0..<100 {
            session.receive(Fixture.blob(other, data: [UInt8](repeating: 0, count: 1024)))
        }
        let outputs = session.drain()
        #expect(outputs.closes.isEmpty)
        #expect(outputs.events.allSatisfy { $0 == .dropped(.unsolicited) })
    }

    @Test func clampsANonsenseLimitsAdvertisementInsteadOfBelievingIt() {
        var limits = Fixture.greedyLimits
        limits.maxBlob = Int(Int32.max)
        let session = Fixture.ready(Fixture.hello(limits: limits))

        #expect(session.isReady)
        #expect(session.limits?.maxBlob == SpoolRecordLayer.maxInboundRecord)
        #expect(session.limits?.maxRecord == SpoolRecordLayer.maxInboundRecord)
        #expect(session.limits?.maxPull == SpoolLimits.maxPullCeiling)
    }

    @Test func aListingForAnotherScopeIsNotAppliedToTheOneWeAskedAbout() throws {
        var session = Fixture.subscribed()
        let listed2 = session.list(scope, now: 0)
        let list = try #require(listed2)
        _ = session.drain()
        session.receive(Fixture.listing(list, scope: other))
        #expect(session.drain().events == [.dropped(.unmatched)])

        session.receive(Fixture.listing(list))
        #expect(session.drain().events == [.answered(request: list, .listing(live: [Fixture.id(5)], tombstones: []))])
    }

    @Test func threeUnansweredRequestsInARowDropTheConnectionAsUnresponsive() throws {
        var session = Fixture.subscribed()
        for round in Int64(0)..<2 {
            let pushed4 = session.push(scope, blobId: other, data: [1], pow: nil, now: round * 40_000)
            _ = try #require(pushed4)
            session.tick(now: round * 40_000 + SpoolSession.requestMilliseconds)
            #expect(session.drain().closes.isEmpty, "two strikes: still open")
        }
        let pushed5 = session.push(scope, blobId: other, data: [1], pow: nil, now: 80_000)
        _ = try #require(pushed5)
        session.tick(now: 80_000 + SpoolSession.requestMilliseconds)
        let outputs = session.drain()

        #expect(outputs.closes == [SpoolCloseCode.normal])
        #expect(outputs.events.last == .ended(fault: .unresponsive))
        #expect(session.fault == .unresponsive)
        let pushed6 = session.push(scope, blobId: other, data: [2], pow: nil, now: 120_000)
        #expect(pushed6 == nil, "nothing more waits on it")
    }

    @Test func anAnswerResetsTheStrikeCountSoSilenceIsOnlyAFaultWhenItIsConsecutive() throws {
        var session = Fixture.subscribed()
        var now: Int64 = 0
        func silentPush() throws {
            let pushed7 = session.push(scope, blobId: other, data: [1], pow: nil, now: now)
            _ = try #require(pushed7)
            now += SpoolSession.requestMilliseconds
            session.tick(now: now)
        }
        try silentPush()
        try silentPush()
        let pushed8 = session.push(scope, blobId: other, data: [1], pow: nil, now: now)
        let answered = try #require(pushed8)
        session.receive(Fixture.ok(answered))
        #expect(session.hasAnswered)
        try silentPush()
        try silentPush()

        #expect(session.drain().closes.isEmpty, "two, an answer, two: never three in a row")
        #expect(session.fault == nil)
    }
}

extension CBOR {
    /// The record with its `t` replaced: a well-formed record under a name this build does not read.
    func replacingType(with type: String) -> [UInt8] {
        guard case .map(let entries) = self else {
            return encoded
        }
        let replaced = entries.map { entry in
            entry.key == .text("t") ? Self.Entry(key: entry.key, value: .text(type)) : entry
        }
        return Self.map(replaced).encoded
    }
}
