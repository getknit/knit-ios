import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Candidates for the spool's door, sealed into a DM scope of the pair's and opened as the heal loop opens them.
enum SpoolCandidates {
    /// `me`'s view of a scope shared with `peer`, from a fixed root.
    static func scope(_ me: TestPeer, _ peer: TestPeer, seed: Int = 40) -> SpoolScope {
        let keys = ScopeCrypto.dmScope(pairwiseRoot: fixtureBytes(32, seed: seed), me.nodeId, peer.nodeId)
        guard let scope = SpoolScope.of(keys, peer: peer.nodeId, retiring: false, retiringUntil: nil) else {
            preconditionFailure("a derived scope id is 32 bytes")
        }
        return scope
    }

    /// `frame` sealed into `me`'s scope with `peer` and opened back as a candidate at `now`.
    static func candidate(
        _ frame: TestFrame, for me: TestPeer, with peer: TestPeer, now: Int64, source: ScopeCandidate.Source = .live
    ) throws -> ScopeCandidate {
        let scope = scope(me, peer)
        let carried = CarriedFrame(envelope: frame.envelope, sig: frame.wire.sig, signed: frame.wire.signed)
        let sealed = try #require(ScopeFrames.seal(carried, into: scope))
        let arrival = SpoolArrival(scope: scope.id, blobId: sealed.id, data: sealed.blob)
        return try #require(ScopeCandidate(opening: arrival, in: scope, me: me.nodeId, source: source, now: now))
    }
}

/// The spool's door alone (``MeshEngine/receiveFromSpool(_:relay:)``, ADR 2026-11.adrq, P4a): Bob's engine with Alice
/// pinned and Carol linked by radio, so a bridge is a write to Carol.
@Suite struct SpoolDoorTests {
    private let alice = ScopeFixture.alice
    private let bob = ScopeFixture.bob
    private let carol = ScopeFixture.carol
    private let relay = SpoolRelayHandle(number: 1)
    private static let hour: Int64 = 3_600_000

    private func bobsEngine(stores: MeshStores = .inMemory()) throws -> EngineFixture {
        let fixture = EngineFixture(bob, stores: stores)
        try fixture.pin(alice)
        fixture.link(carol)
        return fixture
    }

    /// A DM-form frame from Alice to Bob stamped `sentAt`.
    private func dm(_ number: Int, sentAt: Int64) -> TestFrame {
        ScopeFixture.dm(number, from: alice, to: bob, sentAt: sentAt)
    }

    /// Fires the relays due and answers how many copies of `id` went to Carol.
    private func bridged(_ fixture: EngineFixture, _ id: String) -> Int {
        fixture.advance(Router.Configuration().jitterWindowMilliseconds)
        return fixture.transport.written.count { $0.to == carol.nodeId && ExactKey($0.envelope.id) == ExactKey(id) }
    }

    @Test func aFreshFrameIsDeliveredKeptAndBridgedHeardFromNobody() throws {
        let node = try bobsEngine()
        let frame = dm(1, sentAt: node.clock.wallMilliseconds())
        let candidate = try SpoolCandidates.candidate(frame, for: bob, with: alice, now: node.clock.wallMilliseconds())
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: true))
        #expect(bridged(node, frame.envelope.id) == 1, "bridged to the radio neighbour")
        #expect(
            node.engine.routerCounters.spoolAdmitted == 1 && node.engine.routerCounters.admitted == 1, "only the pin was a radio admission")
        #expect(node.engine.spoolInbound.counts.bridged == 1)
    }

    @Test func aFrameCustodyAlreadyHeldIsNotBridgedAgainPastTheRoutersMemory() throws {
        let node = try bobsEngine()
        let frame = dm(1, sentAt: node.clock.wallMilliseconds())
        node.deliver(frame, from: alice)
        let first = bridged(node, frame.envelope.id)
        node.advance(SeenSet.defaultWindowMilliseconds + 1)
        let candidate = try SpoolCandidates.candidate(frame, for: bob, with: alice, now: node.clock.wallMilliseconds())
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: true))
        #expect(bridged(node, frame.envelope.id) == first, "no new send to carol")
        #expect(node.engine.spoolInbound.counts.bridged == 0 && node.engine.spoolInbound.counts.bridgeDeferred == 0)
    }

    @Test func aLateFrameAndOneCustodyRefusesAreDeliveredAccountedAndNotBridged() throws {
        let node = try bobsEngine()
        let now = node.clock.wallMilliseconds()
        for (number, age) in [(1, 49 * Self.hour), (2, 30 * Self.hour)] {
            let frame = dm(number, sentAt: now - age)
            let candidate = try SpoolCandidates.candidate(frame, for: bob, with: alice, now: now)
            #expect(candidate.isLate == (age > 48 * Self.hour))
            #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: false), "accounted by the heal")
            #expect(bridged(node, frame.envelope.id) == 0)
        }
        #expect(node.engine.routerCounters.spoolBridged == 0)
    }

    @Test func aFloodOfFreshFramesIsDeliveredAndKeptAndBridgedWithinTheBudget() throws {
        let node = try bobsEngine()
        let now = node.clock.wallMilliseconds()
        var ids: [ExactKey] = []
        for number in 0..<1000 {
            let frame = dm(number, sentAt: now - 1000 + Int64(number))
            ids.append(ExactKey(frame.envelope.id))
            let candidate = try SpoolCandidates.candidate(frame, for: bob, with: alice, now: now)
            #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: true))
        }
        node.advance(Router.Configuration().jitterWindowMilliseconds)
        let id = Set(ids)
        let toCarol = node.transport.written.count { $0.to == carol.nodeId && id.contains(ExactKey($0.envelope.id)) }
        #expect(toCarol <= SpoolBridgeBudget.capacity, "carol heard at most the bridge's budget")
        #expect(node.engine.spoolInbound.counts.bridged == toCarol && node.engine.spoolInbound.counts.bridgeDeferred == 1000 - toCarol)
    }

    @Test func aSecondRelaysPullOfADeliveredFrameIsDeliveredToo() throws {
        let node = try bobsEngine()
        let frame = dm(1, sentAt: node.clock.wallMilliseconds())
        let candidate = try SpoolCandidates.candidate(frame, for: bob, with: alice, now: node.clock.wallMilliseconds(), source: .pulled)
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: true))
        #expect(node.engine.receiveFromSpool(candidate, relay: SpoolRelayHandle(number: 2)) == .delivered(keptLive: true))
        #expect(
            node.engine.spoolInbound.counts.duplicates == 1 && node.engine.spoolInbound.counts.unopenable == 0
                && node.engine.spoolInbound.counts.refusedByCarry == 0)
        #expect(bridged(node, frame.envelope.id) == 1, "bridged once")
    }

    @Test func anOversizeProfileIsAccountedNotPinnedNorBridged() throws {
        let node = try bobsEngine()
        let pinned = node.stores.peers.peer(alice.nodeId)
        let now = node.clock.wallMilliseconds()
        let huge = try alice.profile(name: "Huge", status: String(repeating: "x", count: 9000), publishedAt: now + 1)
        #expect(huge.wire.signed.count > node.stores.custody.limits.maxProfileSignedBytes)
        let candidate = try SpoolCandidates.candidate(huge, for: bob, with: alice, now: now)
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: false))
        #expect(node.stores.peers.peer(alice.nodeId) == pinned, "nothing pinned")
        #expect(node.engine.profileOversizeRefused == 1 && node.engine.routerCounters.spoolAdmitted == 0, "refused before the router")
        #expect(bridged(node, huge.envelope.id) == 0)
    }

    @Test func anOlderProfileReServedPastTheRoutersMemoryIsNotApplied() throws {
        let node = try bobsEngine()
        node.advance(SeenSet.defaultWindowMilliseconds + 1)
        let older = try alice.profile(name: "Older", publishedAt: node.clock.wallMilliseconds() - Self.hour)
        let candidate = try SpoolCandidates.candidate(older, for: bob, with: alice, now: node.clock.wallMilliseconds())
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: true))
        #expect(node.stores.peers.peer(alice.nodeId)?.name == "Peer", "the pinned version stands")
    }

    @Test func aBadSignatureMarksNothingAndTheGenuineFrameStillLandsAndRelays() throws {
        let node = try bobsEngine()
        let now = node.clock.wallMilliseconds()
        let genuine = dm(1, sentAt: now)
        // Carol signs bytes that claim Alice; then a stranger nobody pinned claims to be the sender.
        let badSignature = try carol.signed(genuine.envelope)
        let candidate = try SpoolCandidates.candidate(badSignature, for: bob, with: alice, now: now)
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .unopenable)
        let stranger = TestPeer(seed: 9)
        let unknown = ScopeFixture.dm(2, from: stranger, to: bob, sentAt: now)
        let strangers = try SpoolCandidates.candidate(unknown, for: bob, with: stranger, now: now)
        #expect(node.engine.receiveFromSpool(strangers, relay: relay) == .unopenable)
        #expect(node.transport.written(.keyRequest).isEmpty, "no key request")
        #expect(node.engine.footprint.parked == 0, "nothing parked")
        node.deliver(genuine, from: alice)
        #expect(node.stores.custody.frame(genuine.envelope.id, now: now) != nil, "the genuine frame is carried")
        #expect(bridged(node, genuine.envelope.id) == 1, "and relayed")
    }

    @Test func aFailedCustodyReadOrWriteIsNotTakenAndTheNextCopyIsNew() throws {
        let failable = FailableStores()
        let node = try bobsEngine(stores: failable.stores)
        let now = node.clock.wallMilliseconds()
        let frame = dm(1, sentAt: now)
        let candidate = try SpoolCandidates.candidate(frame, for: bob, with: alice, now: now)
        failable.custody.failsReads = true
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .notTaken)
        failable.custody.failsReads = false
        failable.custody.failsWrites = true
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .notTaken)
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .notTaken, "a second failure leaves the id unseen too")
        failable.custody.failsWrites = false
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: true))
        #expect(node.stores.custody.frame(frame.envelope.id, now: now) != nil)
        #expect(node.engine.spoolInbound.counts.notTaken == 3)
    }

    @Test func aCustodyReadThatFailsAfterTheDeliveryIsNotTaken() throws {
        let failable = FailableStores()
        let node = try bobsEngine(stores: failable.stores)
        let now = node.clock.wallMilliseconds()
        let first = try SpoolCandidates.candidate(dm(1, sentAt: now), for: bob, with: alice, now: now)
        // The read before the delivery answers; the one after fails.
        failable.custody.framesReadBeforeFailing = 1
        #expect(node.engine.receiveFromSpool(first, relay: relay) == .notTaken)
        failable.custody.framesReadBeforeFailing = nil
        failable.custody.failsReads = false
        #expect(node.engine.receiveFromSpool(first, relay: relay) == .delivered(keptLive: true), "its mark was taken back")
        // Held now: a later copy settles kept with nothing else read.
        #expect(node.engine.receiveFromSpool(first, relay: relay) == .delivered(keptLive: true))
    }

    @Test func aCopyTheRouterSawThatCustodyDoesNotHoldIsCarriedAndDelivered() throws {
        let node = try bobsEngine()
        let now = node.clock.wallMilliseconds()
        let genuine = dm(1, sentAt: now)
        // A copy under the same id whose signature does not verify reaches the router first, over a link.
        node.deliver(try carol.signed(genuine.envelope), from: carol)
        #expect(node.stores.custody.frame(genuine.envelope.id, now: now) == nil, "custody did not carry it")
        let before = node.engine.routerCounters.spoolBridged
        let candidate = try SpoolCandidates.candidate(genuine, for: bob, with: alice, now: now)
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: true))
        #expect(node.stores.custody.frame(genuine.envelope.id, now: now) != nil, "carried now")
        #expect(node.engine.spoolInbound.counts.duplicates == 1 && node.engine.routerCounters.spoolBridged == before, "never bridged")
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: true), "held: nothing else")
    }

    @Test func aRatchetCopyTheRouterSawIsDeliveredFromTheRelay() throws {
        let android = try AndroidPeer(alice)
        let node = try EngineFixture.ratcheting(bob)
        try node.pin(android)
        let now = node.clock.wallMilliseconds()
        let genuine = try android.dm("hello", to: bob, prekey: try node.ourPrekey(), id: frameIdOf("seen-first"), sentAt: now)
        node.deliver(try carol.signed(genuine.envelope), from: carol)
        let candidate = try SpoolCandidates.candidate(genuine, for: bob, with: alice, now: now)
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: true))
        #expect(node.stores.messages.message(genuine.envelope.id)?.body == "hello", "the DM opens with no restart")
    }

    @Test func aKeyReadThatFailsIsNotTakenAndTheNextCopyLands() throws {
        let failable = FailableStores()
        let node = try bobsEngine(stores: failable.stores)
        let now = node.clock.wallMilliseconds()
        let frame = dm(1, sentAt: now)
        let candidate = try SpoolCandidates.candidate(frame, for: bob, with: alice, now: now)
        failable.peers.failsReads = true
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .notTaken)
        failable.peers.failsReads = false
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: true), "nothing was marked seen")
    }

    @Test func aRefusalOfTheFramesOwnBytesIsRefusedByCarryAndMarksNothing() {
        let bytes: [UInt8] = [1, 2]
        let held = MeshEngine.HeldCopy.held(signed: bytes)
        #expect(MeshEngine.pulledAdmission(nil, held: .absent, served: bytes) == .settled(.refusedByCarry), "the carry gate refused it")
        #expect(MeshEngine.pulledAdmission(.nonCanonical, held: held, served: bytes) == .settled(.refusedByCarry))
        #expect(MeshEngine.pulledAdmission(.new, held: .absent, served: bytes) == .new)
        #expect(MeshEngine.pulledAdmission(.refused, held: .absent, served: bytes) == .unheld)
        #expect(MeshEngine.pulledAdmission(.duplicate, held: held, served: [3]) == .settled(.delivered(keptLive: true)))
        #expect(MeshEngine.pulledAdmission(.reopened, held: held, served: bytes) == .settled(.delivered(keptLive: true)), "judged")
        #expect(MeshEngine.pulledAdmission(.reopened, held: held, served: [3]) == .reopened, "other bytes open once")
        #expect(MeshEngine.pulledAdmission(.reopened, held: .absent, served: bytes) == .reopened)
        var inbound = SpoolInbound()
        inbound.note(.refusedByCarry)
        #expect(inbound.counts.refusedByCarry == 1)
    }
}

@Suite struct SpoolBridgeBudgetTests {
    @Test func aClockPastInt64sRangeRefillsTheBucketWhole() {
        var budget = SpoolBridgeBudget(now: -10)
        let spent = (0..<SpoolBridgeBudget.capacity).map { _ in budget.take(now: -10) }
        let far = budget.take(now: Int64.max)
        #expect(spent.count == SpoolBridgeBudget.capacity && far && budget.tokens == SpoolBridgeBudget.capacity - 1)
    }

    @Test func aBurstSpendsTheBucketAndTimeRefillsIt() {
        var budget = SpoolBridgeBudget(now: 0)
        let burst = (0..<SpoolBridgeBudget.capacity).map { _ in budget.take(now: 0) }
        let allTaken = burst.allSatisfy(\.self)
        #expect(allTaken)
        let interval = SpoolBridgeBudget.refillMilliseconds
        let after = [0, interval - 1, interval, interval].map { budget.take(now: $0) }
        #expect(after == [false, false, true, false], "spent, then one back after an interval")
        let far = budget.take(now: Int64.max)
        #expect(far && budget.tokens == SpoolBridgeBudget.capacity - 1, "a far clock refills without overflow")
        let back = budget.take(now: 0)
        #expect(back, "a clock that went back keeps what is left")
    }

    @Test func oneBucketServesEveryRelay() {
        var inbound = SpoolInbound()
        let burst = (0..<SpoolBridgeBudget.capacity).map { _ in inbound.takesBridgeToken(now: 0) }
        let spent = inbound.takesBridgeToken(now: 0)
        let later = inbound.takesBridgeToken(now: SpoolBridgeBudget.refillMilliseconds)
        let allTaken = burst.allSatisfy(\.self)
        #expect(allTaken && !spent && later, "one engine-wide bucket, one token back every two seconds")
        #expect(inbound.counts.bridged == SpoolBridgeBudget.capacity + 1 && inbound.counts.bridgeDeferred == 1)
    }
}
