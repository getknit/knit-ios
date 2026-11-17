import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// Sessions against ``FakeSpool``, the record layer's two sides together: the handshake, a `sub` answered by a digest or
/// refused, a push fanned out to the other member and not back, a duplicate acked without fan-out, a pull and a listing,
/// retention on the spool's own clock, and a `rate` refusal. The heal loop's convergence over it is P3b's.
@Suite struct SpoolSessionFakeSpoolTests {
    private typealias Fixture = SpoolSessionFixture
    private let scope = SpoolSessionFixture.scope

    private func sealed(_ byte: UInt8) -> (id: SpoolID, data: [UInt8]) {
        let data = [UInt8](repeating: byte, count: 40)
        guard let id = SpoolID(ScopeCrypto.blobId(of: data)) else {
            preconditionFailure("a hash is 32 bytes")
        }
        return (id, data)
    }

    private func subscribe(_ line: inout SpoolLine, bounds: ScopeBounds = SpoolSessionFixture.bounds, pow: PowStamp? = nil) {
        _ = line.session.subscribe([ScopeSub(scope: scope.bytes, bounds: bounds, pow: pow)], now: 0)
        line.pump()
    }

    @Test func aSessionConnectsAndASubIsAnsweredWithTheScopesDigest() {
        let spool = FakeSpool()
        var line = SpoolLine(spool)
        #expect(line.takeEvents() == [.connected])
        subscribe(&line)

        #expect(line.takeEvents() == [.digest(scope)])
        #expect(line.session.anchor(scope) == SpoolAnchor(digest: 0, count: 0, full: false))
    }

    @Test func aPushReachesTheOtherMemberLiveAndNeverComesBack() throws {
        let spool = FakeSpool()
        var alice = SpoolLine(spool)
        var bob = SpoolLine(spool)
        subscribe(&alice)
        subscribe(&bob)
        _ = alice.takeEvents()
        _ = bob.takeEvents()
        let blob = sealed(1)

        let pushed1 = alice.session.push(scope, blobId: blob.id, data: blob.data, pow: nil, now: 0)
        let push = try #require(pushed1)
        alice.pump()
        bob.pump()
        #expect(alice.takeEvents() == [.answered(request: push, .stored)])
        #expect(bob.takeEvents() == [.live(SpoolArrival(scope: scope, blobId: blob.id, data: blob.data))])

        // A duplicate is acked with no fan-out (S-7.2-7).
        let pushed2 = bob.session.push(scope, blobId: blob.id, data: blob.data, pow: nil, now: 0)
        let again = try #require(pushed2)
        bob.pump()
        alice.pump()
        #expect(bob.takeEvents() == [.answered(request: again, .stored)])
        #expect(alice.takeEvents().isEmpty)
        #expect(spool.stored == [blob.id])
    }

    @Test func aPullServesWhatTheSpoolHoldsAndNamesTheRestMissing() throws {
        let spool = FakeSpool()
        var line = SpoolLine(spool)
        subscribe(&line)
        let held = sealed(1)
        let gone = sealed(2)
        _ = line.session.push(scope, blobId: held.id, data: held.data, pow: nil, now: 0)
        line.pump()
        _ = line.takeEvents()

        let pulled1 = line.session.pull(scope, [held.id, gone.id], now: 0)
        let pull = try #require(pulled1)
        line.pump()
        #expect(
            line.takeEvents() == [
                .pulled(request: pull, SpoolArrival(scope: scope, blobId: held.id, data: held.data)),
                .answered(request: pull, .pulled(missing: [gone.id], oversize: [])),
            ])
    }

    @Test func retentionRunsOnTheSpoolsClockIntoTombstonesAndTellsEverySubscriber() throws {
        let spool = FakeSpool()
        var line = SpoolLine(spool)
        subscribe(&line, bounds: ScopeBounds(maxFrames: 2, ttlMs: 10_000, maxBlob: 65_536))
        let blobs = (1...3).map { sealed(UInt8($0)) }
        for blob in blobs {
            _ = line.session.push(scope, blobId: blob.id, data: blob.data, pow: nil, now: 0)
            line.pump()
        }
        // The third push evicted the oldest past `maxFrames`, and the spool said so with a digest.
        #expect(spool.liveIds(scope) == [blobs[1].id, blobs[2].id])
        #expect(spool.tombstones(scope) == [blobs[0].id])
        #expect(line.takeEvents().contains(.digest(scope)))
        #expect(line.session.anchor(scope)?.count == 2)

        spool.advance(to: 10_000)
        line.pump()
        #expect(spool.liveIds(scope).count == 2, "a blob lives through its ttlMs, as the daemon keeps it")
        spool.advance(to: 10_001)
        line.pump()
        #expect(spool.liveIds(scope).isEmpty)
        #expect(line.takeEvents() == [.digest(scope)])

        let listed1 = line.session.list(scope, now: 0)
        let list = try #require(listed1)
        line.pump()
        #expect(line.takeEvents() == [.answered(request: list, .listing(live: [], tombstones: [blobs[1].id, blobs[2].id]))])

        let pushed3 = line.session.push(scope, blobId: blobs[1].id, data: blobs[1].data, pow: nil, now: 0)
        let refused = try #require(pushed3)
        line.pump()
        guard case .answered(refused, .refused(let refusal)) = line.takeEvents().first else {
            Issue.record("a tombstoned blob is refused")
            return
        }
        #expect(refusal.code.is(SpoolErrorCode.tombstoned))
    }

    @Test func aSubIsRefusedPowWithoutAStampAndQuotaPastTheSpoolsCap() throws {
        let spool = FakeSpool(powBits: 8)
        var line = SpoolLine(spool)
        subscribe(&line)
        guard case .scopeRefused(scope, let pow) = line.takeEvents().last else {
            Issue.record("an unknown scope wants a stamp")
            return
        }
        #expect(pow.code.is(SpoolErrorCode.pow))
        #expect(!line.session.isSubscribed(scope))

        let day = SpoolPow.utcDay(nowMs: spool.now)
        let counter = try #require(SpoolPow.mine(scopeId: scope.bytes, day: day, bits: 8))
        subscribe(&line, pow: PowStamp(counter: counter, day: day))
        #expect(line.takeEvents() == [.digest(scope)])

        let full = FakeSpool()
        full.scopeQuota = 0
        full.quotaRetryMs = 7_200_000
        var crowded = SpoolLine(full)
        subscribe(&crowded)
        guard case .scopeRefused(scope, let quota) = crowded.takeEvents().last else {
            Issue.record("a full spool refuses a new scope")
            return
        }
        #expect(quota.parkMilliseconds == SpoolSession.maxParkMilliseconds)
    }

    @Test func aPlantedRefusalAndARateLimitAreTheSpoolsToSay() throws {
        let spool = FakeSpool()
        var line = SpoolLine(spool)
        spool.refuseSub(scope, code: SpoolErrorCode.quota, retryMs: 1)
        subscribe(&line)
        #expect(line.takeEvents().last.map { if case .scopeRefused = $0 { true } else { false } } == true)
        subscribe(&line)
        _ = line.takeEvents()

        spool.ratedPushes = 1
        spool.rateRetryMs = 2500
        let blob = sealed(1)
        let pushed4 = line.session.push(scope, blobId: blob.id, data: blob.data, pow: nil, now: 0)
        let push = try #require(pushed4)
        line.pump()
        guard case .answered(push, .refused(let rate)) = line.takeEvents().first else {
            Issue.record("a rated push is refused")
            return
        }
        #expect(rate.rateWaitMilliseconds == 2500)
    }

    @Test func theSpoolClosesAClientThatSpeaksBeforeItsHello() {
        let spool = FakeSpool()
        let connection = spool.connect()
        spool.receive(SpoolList(request: 1, scope: scope.bytes).encoded, from: connection)
        #expect(spool.take(connection).last == .close(SpoolCloseCode.malformed))
        #expect(!spool.isOpen(connection))
    }

    @Test func aScopeOperationBeforeItsSubIsRefusedNotSubscribed() {
        let spool = FakeSpool()
        let connection = spool.connect()
        spool.receive(SpoolHello.client.encoded, from: connection)
        _ = spool.take(connection)
        spool.receive(SpoolPull(request: 3, scope: scope.bytes, blobIds: []).encoded, from: connection)
        #expect(spool.take(connection) == [.record(SpoolErr(code: SpoolErrorCode.notSubscribed, request: 3, scope: scope.bytes).encoded)])
    }

    @Test func aHostileSpoolCanSayAnythingAndTheSessionKeepsItsFooting() {
        let spool = FakeSpool()
        var line = SpoolLine(spool)
        subscribe(&line)
        _ = line.takeEvents()
        spool.inject(Fixture.blob(Fixture.id(9)), into: line.connection)
        spool.inject(Fixture.hello(), into: line.connection)
        line.pump()
        #expect(line.takeEvents() == [.dropped(.unsolicited), .dropped(.lateHello)])
        #expect(line.closes.isEmpty)
    }

    @Test func aSpoolSpeakingAnotherVersionIsClosed4002() {
        let spool = FakeSpool(version: 2, minimum: 2)
        var line = SpoolLine(spool)
        #expect(line.closes == [SpoolCloseCode.version])
        #expect(line.takeEvents() == [.ended(fault: .version)])
    }
}
