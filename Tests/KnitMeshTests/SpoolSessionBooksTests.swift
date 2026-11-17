import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// The per-connection books the heal loop reads (anchors, claims, the subscribed set) and the session's small types: what
/// dies with a connection, and what a log line may carry.
@Suite struct SpoolSessionBooksTests {
    private typealias Fixture = SpoolSessionFixture
    private let scope = SpoolSessionFixture.scope
    private let other = SpoolSessionFixture.other

    @Test func aDigestSetsTheAnchorAndOnlyAChangeCuesAHeal() {
        var session = Fixture.subscribed()
        session.receive(Fixture.digest())
        session.receive(Fixture.digest())
        session.receive(Fixture.digest(count: 2))
        session.receive(Fixture.digest(value: [0, 0, 0, 0, 0, 0, 0, 9], count: 2))

        #expect(session.drain().events == [.digest(scope), .digest(scope), .digest(scope)])
        #expect(session.anchor(scope) == SpoolAnchor(digest: 9, count: 2, full: false))
    }

    @Test func aPushFoldsIntoAnAnchorOnlyWhereOneExists() {
        var session = Fixture.subscribed()
        session.foldPushed(scope, blobId: other)
        #expect(session.anchor(scope) == nil, "no digest the spool never sent")

        session.receive(Fixture.digest(value: [UInt8](repeating: 0, count: 8), count: 0))
        session.foldPushed(scope, blobId: other)
        #expect(session.anchor(scope) == SpoolAnchor(digest: ScopeCrypto.fnv64(other.bytes), count: 1, full: false))

        session.receive(Fixture.digest(count: Int(Int32.max)))
        session.anchors[scope]?.count = .max
        session.foldPushed(scope, blobId: other)
        #expect(session.anchor(scope)?.count == .max, "a count never traps")
    }

    @Test func aReanchorLandsOnlyOverTheDigestTheListingRanAgainst() {
        var session = Fixture.subscribed()
        let moved1 = session.reanchor(scope, over: 7, to: 9, count: 3)
        #expect(!moved1)
        session.receive(Fixture.digest())
        let moved2 = session.reanchor(scope, over: 8, to: 9, count: 3)
        #expect(!moved2, "a newer digest landed meanwhile")
        let moved3 = session.reanchor(scope, over: 7, to: 9, count: 3)
        #expect(moved3)
        #expect(session.anchor(scope) == SpoolAnchor(digest: 9, count: 3, full: false))
    }

    @Test func aClaimHoldsOncePerIdPerConnectionAndIsBounded() {
        var session = Fixture.subscribed()
        let claimed1 = session.claim(other, blobId: scope)
        #expect(!claimed1, "an unsubscribed scope claims nothing")
        let claimed2 = session.claim(scope, blobId: other)
        #expect(claimed2)
        let claimed3 = session.claim(scope, blobId: other)
        #expect(!claimed3)
        session.release(scope, blobId: other)
        session.release(scope, blobId: Fixture.id(9))
        let claimed4 = session.claim(scope, blobId: other)
        #expect(claimed4)

        session.settle(scope)

        // Claiming never evicts (`ScopeSync.claim`): garbage claimed and released costs the guard nothing.
        for number in 0..<SpoolSession.maxClaimsPerScope + 100 {
            let junk = session.claim(scope, blobId: Fixture.numbered(number))
            #expect(junk)
            session.release(scope, blobId: Fixture.numbered(number))
        }
        let settled = session.claim(scope, blobId: other)
        #expect(!settled, "a delivered id is still excluded")

        // Settling holds the set to its bound, the oldest going first.
        for number in 0..<SpoolSession.maxClaimsPerScope {
            _ = session.claim(scope, blobId: Fixture.numbered(number))
        }
        #expect(session.claims[scope]?.count == SpoolSession.maxClaimsPerScope + 1)
        session.settle(scope)
        session.settle(other)
        #expect(session.claims[scope]?.count == SpoolSession.maxClaimsPerScope)
        let evicted = session.claim(scope, blobId: other)
        #expect(evicted, "the oldest went at the settle")
    }

    @Test func forgettingASubscriptionTakesItsBooksWithIt() {
        var session = Fixture.subscribed([scope, other])
        session.receive(Fixture.digest())
        session.receive(Fixture.digest(other))
        _ = session.claim(scope, blobId: other)
        _ = session.claim(other, blobId: scope)
        session.retainSubscriptions([other])

        #expect(!session.isSubscribed(scope))
        #expect(session.anchor(scope) == nil)
        let claimed7 = session.claim(scope, blobId: other)
        #expect(claimed7 == false)
        #expect(session.anchor(other) != nil)
        #expect(session.bookSize == 3)

        session.socketClosed()
        session.socketClosed()
        #expect(session.bookSize == 0)
        #expect(session.drain().events.filter { $0 == .ended(fault: nil) }.count == 1)
    }

    @Test func aSubNamesEachScopeOnceRedeclaresFreelyAndTakesNoMoreRoomThanTheSpoolHas() {
        var limits = Fixture.smallLimits
        limits.maxScopes = 2
        var session = Fixture.ready(Fixture.hello(limits: limits))
        let sub = { (id: SpoolID) in ScopeSub(scope: id.bytes, bounds: Fixture.bounds) }

        let subscribed1 = session.subscribe([sub(scope), sub(scope), ScopeSub(scope: [1, 2], bounds: Fixture.bounds)], now: 0)
        #expect(subscribed1 == [scope])
        let subscribed2 = session.subscribe([sub(scope), sub(other), sub(Fixture.id(5))], now: 0)
        #expect(subscribed2 == [scope, other])
        let subscribed3 = session.subscribe([sub(Fixture.id(5))], now: 0)
        #expect(subscribed3.isEmpty)
        let subscribed4 = session.subscribe([], now: 0)
        #expect(subscribed4.isEmpty)
        let records = session.drain().records
        #expect(records.count == 2)
        guard case .sub(let second) = records.last else {
            Issue.record("expected a sub, got \(records)")
            return
        }
        #expect(second.request == 2)
    }

    @Test func nothingIsAskedBeforeTheHelloOrOfAnUnsubscribedScope() {
        var waiting = SpoolSession(openedAt: 0)
        let subscribed5 = waiting.subscribe([ScopeSub(scope: scope.bytes, bounds: Fixture.bounds)], now: 0)
        #expect(subscribed5.isEmpty)
        let listed1 = waiting.list(scope, now: 0)
        #expect(listed1 == nil)
        #expect(waiting.nextDeadline == SpoolSession.handshakeMilliseconds)

        var session = Fixture.subscribed()
        let listed2 = session.list(other, now: 0)
        #expect(listed2 == nil)
        let pulled1 = session.pull(scope, [], now: 0)
        #expect(pulled1 == nil)
        #expect(session.nextDeadline == nil)
        session.tick(now: 1)
        #expect(session.drain().isEmpty)
    }

    @Test func aSpoolWithoutLimitsIsHeldToOursAlone() {
        var session = Fixture.subscribed(hello: Fixture.hello(minimum: nil, limits: nil, powBits: nil))
        #expect(session.limits == nil)
        #expect(session.powBits == 0)
        let ids = (0..<SpoolLimits.maxPullCeiling).map(Fixture.numbered)
        let pulled2 = session.pull(scope, ids, now: 0)
        #expect(pulled2 != nil)
        let pulled3 = session.pull(scope, ids + [other], now: 0)
        #expect(pulled3 == nil)
    }

    @Test func eachKindOfRequestIsAnsweredInItsOwnShape() throws {
        var session = Fixture.subscribed()
        let listed3 = session.list(scope, now: 0)
        let list = try #require(listed3)
        let pushed1 = session.push(scope, blobId: other, data: [1], pow: nil, now: 0)
        let push = try #require(pushed1)
        let pushed2 = session.push(scope, blobId: other, data: [1], pow: nil, now: 0)
        let refused = try #require(pushed2)
        _ = session.drain()
        session.receive(Fixture.ok(list))
        session.receive(Fixture.ok(push))
        session.receive(Fixture.err(SpoolErrorCode.tombstoned, request: refused, scope: scope.bytes))
        session.receive(Fixture.listing(push))
        session.receive(Fixture.err(SpoolErrorCode.internal))

        let events = session.drain().events
        #expect(events.prefix(2) == [.answered(request: list, .unanswered), .answered(request: push, .stored)])
        guard case .answered(refused, .refused(let refusal)) = events[2], case .spoolError(let error) = events[4] else {
            Issue.record("expected a refused push and a connection error, got \(events)")
            return
        }
        #expect(refusal.code.is(SpoolErrorCode.tombstoned))
        #expect(error.code.is(SpoolErrorCode.internal))
        #expect(events[3] == .dropped(.unmatched))
    }

    @Test func aLiveEventPastTheDeclaredMaxBlobIsDropped() {
        var session = Fixture.subscribed()
        session.receive(Fixture.event(other, data: [UInt8](repeating: 0, count: SpoolRecordLayer.defaultMaxBlob + 1)))
        session.receive(Fixture.event(other))
        #expect(
            session.drain().events == [.dropped(.oversize), .live(SpoolArrival(scope: scope, blobId: other, data: [7]))])
    }

    @Test func aClosedSessionReadsNothingAndAbortsOnce() {
        var session = Fixture.subscribed()
        session.end(.unresponsive)
        session.end(.noHello)
        session.receive(Fixture.digest())
        session.tick(now: 1_000_000)
        #expect(session.fault == .unresponsive)
        #expect(session.drain() == [.close(code: SpoolCloseCode.normal), .event(.ended(fault: .unresponsive))])
    }

    @Test func noOutputPrintsAWholeIdOrABlobsBytes() {
        let blobId = Fixture.id(0x40)
        let data = [UInt8](repeating: 0xAB, count: 40)
        let arrival = SpoolArrival(scope: scope, blobId: blobId, data: data)
        let shown: [Any] = [
            scope, arrival, SpoolSessionOutput.send(scope.bytes + data), SpoolSessionOutput.event(.live(arrival)),
            SpoolSessionOutput.event(.pulled(request: 3, arrival)), SpoolSessionEvent.live(arrival),
            SpoolSessionEvent.answered(request: 3, .listing(live: [blobId], tombstones: [scope])),
            SpoolReply.pulled(missing: [blobId], oversize: [scope]),
        ]
        let fullIds = [scope, blobId].flatMap { id in
            ["\(id.bytes)", id.bytes.map { String($0) }.joined(separator: ", "), Self.hex(id.bytes)]
        }
        for value in shown {
            var dumped = ""
            dump(value, to: &dumped)
            for text in ["\(value)", String(reflecting: value), dumped] {
                #expect(!fullIds.contains { text.contains($0) }, "\(text)")
                #expect(!text.contains("171, 171"), "\(text)")
            }
        }
        #expect("\(arrival)" == "00010203/40414243, 40 bytes")
        #expect("\(SpoolSessionOutput.send(data))" == "send(40 bytes)")
        #expect(String(reflecting: SpoolSessionOutput.close(code: 1000)) == "close(1000)")
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    @Test func anIdShowsAShortPrefixAndNothingElse() {
        #expect(Fixture.id(0).description == "00010203")
        #expect(Fixture.id(0x1C).description == "1c1d1e1f")
        #expect(SpoolID([UInt8](repeating: 0, count: 31)) == nil)
    }

    @Test func spoolTextNeverSplitsASurrogatePairAndMatchesByBytes() {
        let cut = SpoolText(String(repeating: "a", count: 31) + "\u{1F600}")
        #expect(cut.text == String(repeating: "a", count: 31))
        #expect(SpoolText("rate").is(SpoolErrorCode.rate))
        #expect(!SpoolText("K").is("\u{212A}"))
        #expect("\(SpoolText("quota\u{0}"))" == "quota")
    }
}
