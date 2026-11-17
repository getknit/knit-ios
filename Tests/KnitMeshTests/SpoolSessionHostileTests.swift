import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// What a hostile spool can send one connection (P1's security review, P3's design passes; ADR 2026-11.adrq): every case
/// ends without a trap, in Kotlin's outcome or a stricter one, and leaves the session's books bounded.
@Suite struct SpoolSessionHostileTests {
    private typealias Fixture = SpoolSessionFixture
    private let scope = SpoolSessionFixture.scope
    private let other = SpoolSessionFixture.other

    @Test func anOversizeRecordIsDroppedUnread() {
        var session = Fixture.subscribed()
        session.receive(Fixture.blob(other, data: [UInt8](repeating: 1, count: SpoolRecordLayer.maxInboundRecord)))
        #expect(session.drain().events == [.dropped(.undecodable)])
    }

    @Test(arguments: [0, 31, 33, 64])
    func anIdThatIsNot32BytesStartsNothing(length: Int) throws {
        var session = Fixture.subscribed()
        let pulled1 = session.pull(scope, [other], now: 0)
        let pull = try #require(pulled1)
        _ = session.drain()
        let bad = [UInt8](repeating: 9, count: length)
        session.receive(
            SpoolDigest(scope: bad, digest: [UInt8](repeating: 0, count: 8), count: 1, full: false, bounds: Fixture.bounds).encoded)
        session.receive(SpoolEvent(scope: scope.bytes, blobId: bad, data: [1]).encoded)
        session.receive(SpoolBlob(scope: bad, blobId: other.bytes, data: [1]).encoded)
        session.receive(SpoolBlob(scope: scope.bytes, blobId: bad, data: [1]).encoded)
        session.receive(SpoolList(request: pull, scope: bad).encoded)
        session.receive(Fixture.err(SpoolErrorCode.quota, request: pull, scope: bad))

        #expect(session.drain().events == Array(repeating: .dropped(.malformed), count: 6))
        #expect(session.isSubscribed(scope), "a malformed err unsubscribes nothing")
        #expect(session.anchor(scope) == nil)
        #expect(session.nextDeadline == SpoolSession.requestMilliseconds, "nor answers the pull")
    }

    @Test(arguments: [0, 7, 9])
    func aDigestThatIsNot8BytesIsAFaultOfThatRecord(length: Int) {
        var session = Fixture.subscribed()
        session.receive(Fixture.digest(value: [UInt8](repeating: 1, count: length)))
        #expect(session.drain().events == [.dropped(.malformed)])
        #expect(session.anchor(scope) == nil)
    }

    @Test func aNegativeCountIsAnEchoAndNeverASize() {
        var session = Fixture.subscribed()
        session.receive(Fixture.digest(count: -1))
        #expect(session.drain().events == [.digest(scope)])
        #expect(session.anchor(scope) == SpoolAnchor(digest: 7, count: -1, full: false))
    }

    @Test(arguments: [Int64(-1), .max, .min, 0])
    func retryMsIsReadOnlyThroughClamps(retryMs: Int64) throws {
        var session = Fixture.subscribed([scope, other])
        let pushed1 = session.push(scope, blobId: other, data: [1], pow: nil, now: 0)
        let push = try #require(pushed1)
        _ = session.drain()
        session.receive(Fixture.err(SpoolErrorCode.rate, request: push, scope: scope.bytes, retryMs: retryMs))
        session.receive(Fixture.err(SpoolErrorCode.quota, request: 99, scope: other.bytes, retryMs: retryMs))
        let events = session.drain().events

        guard case .answered(_, .refused(let rate)) = events.first, case .scopeRefused(_, let quota) = events.last else {
            Issue.record("expected a refused push and a refused scope, got \(events)")
            return
        }
        #expect((0...SpoolSession.maxRateWaitMilliseconds).contains(rate.rateWaitMilliseconds))
        #expect((SpoolSession.minParkMilliseconds...SpoolSession.maxParkMilliseconds).contains(quota.parkMilliseconds))
    }

    @Test func aRefusalWithoutRetryMsWaitsTheCeilingAndParksTheFloor() {
        let refusal = SpoolRefusal(SpoolErr(code: SpoolErrorCode.rate))
        #expect(refusal.rateWaitMilliseconds == SpoolSession.maxRateWaitMilliseconds)
        #expect(refusal.parkMilliseconds == SpoolSession.minParkMilliseconds)
        #expect(refusal.message == nil)
    }

    @Test func aBlobNoPullNamedAndASecondBlobForOneIdAreDropped() throws {
        var session = Fixture.subscribed()
        session.receive(Fixture.blob(other))
        let pulled4 = session.pull(scope, [other], now: 0)
        let pull = try #require(pulled4)
        _ = session.drain()
        session.receive(Fixture.blob(other))
        session.receive(Fixture.blob(other))

        #expect(
            session.drain().events == [
                .pulled(request: pull, SpoolArrival(scope: scope, blobId: other, data: [7])), .dropped(.unsolicited),
            ])
    }

    @Test func recordsForAnUnsubscribedScopeAreDroppedBeforeAnythingReadsThem() {
        var session = Fixture.subscribed()
        session.receive(Fixture.digest(other))
        session.receive(Fixture.event(Fixture.id(5), scope: other))
        session.receive(Fixture.blob(Fixture.id(5), scope: other))
        session.receive(Fixture.err(SpoolErrorCode.quota, scope: other.bytes))

        #expect(session.drain().events == Array(repeating: .dropped(.unsubscribed), count: 4))
        #expect(session.anchor(other) == nil)
        #expect(session.bookSize == 1, "the subscription alone")
    }

    @Test func anOkForAnUnissuedQIsNoReply() {
        var session = Fixture.subscribed()
        session.receive(Fixture.ok(42))
        #expect(session.drain().events == [.dropped(.unmatched)])
        #expect(!session.hasAnswered)
    }

    @Test func okMissingIsHeldToTheIdsThePullNamedAndWasNotServed() throws {
        var session = Fixture.subscribed()
        let pulled5 = session.pull(scope, [other, Fixture.id(5)], now: 0)
        let pull = try #require(pulled5)
        _ = session.drain()
        session.receive(Fixture.blob(other))
        let outsider = SpoolOk(request: pull, missing: [Fixture.id(9).bytes, other.bytes, Fixture.id(5).bytes, [1, 2]])
        session.receive(outsider.encoded)

        #expect(session.drain().events.last == .answered(request: pull, .pulled(missing: [Fixture.id(5)], oversize: [])))
    }

    @Test func aPullServedOneBlobEvery29SecondsStillTimesOut30SecondsAfterItWasSent() throws {
        var limits = Fixture.smallLimits
        limits.maxPull = SpoolLimits.maxPullCeiling
        limits.maxRecord = SpoolRecordLayer.maxInboundRecord
        var session = Fixture.subscribed(hello: Fixture.hello(limits: limits))
        let ids = (0..<256).map(Fixture.numbered)
        let pulled6 = session.pull(scope, ids, now: 0)
        let pull = try #require(pulled6)
        _ = session.drain()

        session.tick(now: 29_000)
        session.receive(Fixture.blob(ids[0]))
        #expect(session.nextDeadline == SpoolSession.requestMilliseconds, "a blob never stretches the request")
        session.tick(now: 30_000)
        #expect(session.drain().events.last == .answered(request: pull, .unanswered))

        session.tick(now: 58_000)
        session.receive(Fixture.blob(ids[1]))
        #expect(session.drain().events == [.dropped(.unsolicited)])
    }

    @Test func tenThousandJunkRecordsLeaveTheBooksBounded() throws {
        var session = Fixture.subscribed()
        let named = [other, Fixture.numbered(0)]
        let pulled7 = session.pull(scope, named, now: 0)
        _ = try #require(pulled7)
        // The pull's entry and its named ids, and the subscription: what the flood may not add to but one anchor.
        let bound = session.bookSize + 1
        #expect(bound == 1 + named.count + 1 + 1)
        for index in 0..<10_000 {
            let junk = Fixture.id(1 + index % 200)
            let value = (0..<8).map { UInt8(truncatingIfNeeded: index >> ($0 * 2)) }
            let records = [
                Fixture.blob(junk), Fixture.digest(junk), Fixture.ok(Int64(1_000_000 + index)), Fixture.event(junk, scope: junk),
                Fixture.err("x\(index)", scope: junk.bytes), [UInt8(truncatingIfNeeded: index)],
                Fixture.digest(value: value, count: index), Fixture.event(junk, data: [UInt8](repeating: 1, count: index % 64)),
            ]
            session.receive(records[index % records.count])
            _ = session.drain()
            #expect(session.bookSize <= bound)
        }
    }

    @Test func spoolStringsAreCutAndCleanedBeforeTheyLeave() throws {
        var session = Fixture.subscribed()
        let pushed2 = session.push(scope, blobId: other, data: [1], pow: nil, now: 0)
        let push = try #require(pushed2)
        _ = session.drain()
        let code = "rate\u{202E}\u{0007}\n" + String(repeating: "y", count: 100)
        session.receive(Fixture.err(code, request: push, message: "line\u{2028}two"))
        session.receive(SpoolErr(code: "x").cbor.replacingType(with: "evil\u{1B}[31m" + String(repeating: "z", count: 40)))
        let events = session.drain().events

        guard case .answered(_, .refused(let refusal)) = events.first, case .dropped(.unknown(let type)) = events.last else {
            Issue.record("expected a refusal and an unknown record, got \(events)")
            return
        }
        #expect(refusal.code.text == "rate" + String(repeating: "y", count: 28))
        #expect(refusal.message?.text == "linetwo")
        #expect(type.text.utf16.count == SpoolText.maxUTF16)
        #expect(!type.text.unicodeScalars.contains { $0.properties.generalCategory == .control })
    }

    @Test func aTicketErrDropsNoScope() {
        var session = Fixture.subscribed()
        session.receive(Fixture.err(SpoolErrorCode.ticket, scope: scope.bytes, message: "missing"))
        #expect(session.drain().events == [.dropped(.unmatched)])
        #expect(session.isSubscribed(scope))
    }

    @Test func aRecordOnlyTheClientSendsIsDropped() {
        var session = Fixture.subscribed()
        session.receive(SpoolPull(request: 1, scope: scope.bytes, blobIds: [other.bytes]).encoded)
        #expect(session.drain().events == [.dropped(.unmatched)])
    }

    @Test func aClockAtTheEndOfItsRangeNeverTraps() throws {
        var session = Fixture.subscribed(now: .max - 1)
        let pushed4 = session.push(scope, blobId: other, data: [1], pow: nil, now: .max - 1)
        _ = try #require(pushed4)
        #expect(session.nextDeadline == .max)
        #expect(SpoolSession.later(.max, by: 1) == .max)
        #expect(SpoolSession.later(-5, by: 1) == -4)
    }
}
