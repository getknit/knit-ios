import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// What a hostile spool can put in its `hello` and around it (P1's security review; ADR 2026-11.adrq): its versions, its
/// limits and its difficulty, each held to what this client tracks, and records that come before it, after it or in its
/// place. Every case ends without a trap, in Kotlin's outcome or a stricter one.
@Suite struct SpoolSessionHelloTests {
    private typealias Fixture = SpoolSessionFixture
    private let scope = SpoolSessionFixture.scope
    private let other = SpoolSessionFixture.other

    @Test(arguments: [0, -1, Int(Int32.max)])
    func helloMaxPullIsHeldTo1Through256(maxPull: Int) throws {
        var limits = Fixture.smallLimits
        limits.maxPull = maxPull
        limits.maxRecord = SpoolRecordLayer.maxInboundRecord
        var session = Fixture.subscribed(hello: Fixture.hello(limits: limits))
        let held = try #require(session.limits?.maxPull)

        #expect((1...SpoolLimits.maxPullCeiling).contains(held))
        let pulled2 = session.pull(scope, (0..<held).map(Fixture.numbered), now: 0)
        #expect(pulled2 != nil)
        let pulled3 = session.pull(scope, (0...held).map(Fixture.numbered), now: 0)
        #expect(pulled3 == nil, "the caller batches at maxPull")
    }

    @Test(arguments: [0, -1])
    func helloMaxScopesBelowOneStillTakesOne(maxScopes: Int) {
        var limits = Fixture.smallLimits
        limits.maxScopes = maxScopes
        var session = Fixture.ready(Fixture.hello(limits: limits))

        let subscribed1 = session.subscribe([ScopeSub(scope: scope.bytes, bounds: Fixture.bounds)], now: 0)
        #expect(subscribed1 == [scope])
        let subscribed2 = session.subscribe([ScopeSub(scope: other.bytes, bounds: Fixture.bounds)], now: 0)
        #expect(subscribed2.isEmpty, "no room for a second")
    }

    @Test func helloMaxBlobZeroBoundsNothingThisSideDeclared() {
        var limits = Fixture.smallLimits
        limits.maxBlob = 0
        var session = Fixture.subscribed(hello: Fixture.hello(limits: limits))
        session.receive(Fixture.event(other, data: [UInt8](repeating: 1, count: 100)))
        #expect(session.drain().events == [.live(SpoolArrival(scope: scope, blobId: other, data: [UInt8](repeating: 1, count: 100)))])
    }

    @Test(arguments: [(1, 2), (5, 7), (0, 0)] as [(Int, Int)])
    func aHelloWhoseRangeLeavesVersion1OutCloses4002(version: Int, minimum: Int) {
        var session = SpoolSession(openedAt: 0)
        session.receive(Fixture.hello(version: version, minimum: minimum))
        #expect(session.drain().closes == [SpoolCloseCode.version])
    }

    @Test(arguments: [(Int(-1), 0), (64, SpoolPow.maxBits), (24, 24), (Int(Int32.max), 24)] as [(Int, Int)])
    func powBitsAreHeldTo0Through24(advertised: Int, held: Int) {
        #expect(Fixture.ready(Fixture.hello(powBits: advertised)).powBits == held)
    }

    @Test func aSecondHelloIsIgnoredAndRecordsBeforeTheFirstAreDropped() {
        var session = SpoolSession(openedAt: 0)
        session.receive(Fixture.digest())
        session.receive(Fixture.ok(1))
        session.receive(Fixture.hello(powBits: 8))
        session.receive(Fixture.hello(powBits: 20))
        let events = session.drain().events

        #expect(events == [.dropped(.beforeHello), .dropped(.beforeHello), .connected, .dropped(.lateHello)])
        #expect(session.powBits == 8)
    }

    @Test func anUnreadableHelloCloses4002AsKotlinsDoes() {
        var session = SpoolSession(openedAt: 0)
        // A text `t` of "hello" whose `v` is text: kotlinx refuses the hello, and `onHello` closes 4002.
        session.receive(
            CBOR.map([CBOR.Entry(key: .text("t"), value: .text("hello")), CBOR.Entry(key: .text("v"), value: .text("1"))]).encoded)
        #expect(session.drain().closes == [SpoolCloseCode.version])
    }

    @Test func unreadableBytesThatNameNoHelloWaitOutTheHandshake() {
        var session = SpoolSession(openedAt: 0)
        session.receive([0xFF])
        session.receive(CBOR.array([]).encoded)
        session.receive(CBOR.map([CBOR.Entry(key: .unsigned(1), value: .text("hello"))]).encoded)
        session.receive(CBOR.map([CBOR.Entry(key: .text("t"), value: .unsigned(1))]).encoded)
        session.receive(CBOR.map([CBOR.Entry(key: .text("u"), value: .text("hello"))]).encoded)
        session.receive([UInt8](repeating: 0xA0, count: SpoolRecordLayer.maxInboundRecord + 1))
        #expect(session.drain().events == Array(repeating: .dropped(.undecodable), count: 6))

        session.tick(now: SpoolSession.handshakeMilliseconds - 1)
        #expect(session.drain().isEmpty)
        session.tick(now: SpoolSession.handshakeMilliseconds)
        #expect(session.drain() == [.close(code: SpoolCloseCode.normal), .event(.ended(fault: .noHello))])
    }

    @Test func aMaxRecordTooSmallForOurReplyFailsTheHandshake() {
        var limits = Fixture.smallLimits
        limits.maxRecord = 11
        var session = SpoolSession(openedAt: 0)
        session.receive(Fixture.hello(limits: limits))
        #expect(session.drain() == [.close(code: SpoolCloseCode.normal), .event(.ended(fault: .noHello))])
    }

    @Test func aMaxRecordTooSmallForASubEndsTheConnection() {
        var limits = Fixture.smallLimits
        limits.maxRecord = 12
        var session = Fixture.ready(Fixture.hello(limits: limits))
        let subscribed3 = session.subscribe([ScopeSub(scope: scope.bytes, bounds: Fixture.bounds)], now: 0)
        #expect(subscribed3.isEmpty)
        #expect(session.fault == .tooLarge)
        #expect(session.drain().closes == [SpoolCloseCode.normal])
    }
}
