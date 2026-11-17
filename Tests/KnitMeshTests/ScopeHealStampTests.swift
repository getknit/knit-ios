import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The heal's stamp rules this port adds in P4b2 (ADR 2026-11.adrq): a stamp is sent only while the bits it meets reach
/// the session's, and a retiring scope about to leave the table asks for no search.
@Suite struct ScopeHealStampTests {
    private typealias Fixture = ScopeFixture
    private let scope = ScopeFixture.scope(for: ScopeFixture.alice).id

    /// Alice's view of the pair's scope as a retiring one whose drain ends at `until`.
    private static func retiring(until: Int64) -> SpoolScope? {
        SpoolScope.of(Fixture.keys(), peer: Fixture.bob.nodeId, retiring: true, retiringUntil: until)
    }

    /// Alice carrying `scope` alone on a spool that asks 8 bits, her searches held.
    private static func member(_ scope: SpoolScope) -> HealMember {
        HealMember(
            Fixture.alice,
            spool: FakeSpool(powBits: 8, now: Fixture.wall),
            scopes: [scope],
            at: SpoolNow(monotonic: 0, wall: Fixture.wall),
            minesStamps: false
        )
    }

    @Test func aStampThatMeetsFewerBitsThanTheHelloAsksIsNotReused() throws {
        // The deepest spool, at most 16 bits, whose first stamp for this scope today meets fewer than 20 bits.
        let day = SpoolPow.utcDay(nowMs: Fixture.wall)
        let low = try #require(
            (12...16).reversed().first { bits in
                SpoolPow.mine(scopeId: scope.bytes, day: day, bits: bits).counter.map { counter in
                    SpoolPow.leadingZeroBits(SpoolPow.digest(scopeId: scope.bytes, day: day, n: counter)) < 20
                } == true
            })
        let spool = FakeSpool(powBits: low, now: Fixture.wall)
        let alice = HealMember(
            Fixture.alice, spool: spool, scopes: [Fixture.scope(for: Fixture.alice)], at: SpoolNow(monotonic: 0, wall: Fixture.wall))
        let state = try #require(alice.heal.state(scope))
        let stamp = try #require(state.stamp, "a stamp was mined")
        #expect(state.stampBits >= low && state.stampBits < 20, "the stamp meets fewer than 20 bits")
        #expect(SpoolPow.verify(scopeId: scope.bytes, day: stamp.day, n: stamp.counter, bits: state.stampBits))
        let asked = alice.mineRequests.count
        // The spool loses the scope and now asks 20 bits.
        spool.forget(scope)
        spool.powBits = 20
        alice.minesStamps = false
        alice.reconnect()
        let request = try #require(alice.pendingMining.first, "a 20-bit search is asked")
        #expect(request.bits == 20 && alice.mineRequests.count == asked + 1)
        #expect(alice.subs.last?.subs.first?.pow == nil, "the shallower stamp never went to the 20-bit spool")
        #expect(alice.heal.usableStamp(scope, session: alice.session, now: alice.now) == nil)
    }

    @Test func aRetiringScopeWhoseDrainEndsWithinTheReconcileAsksNoSearchAndParksUntilItLeaves() throws {
        let soon = try #require(Self.retiring(until: Fixture.wall + SpoolPlane.reconcileMilliseconds / 2))
        let alice = Self.member(soon)
        #expect(alice.mineRequests.isEmpty, "no search for a scope about to leave")
        #expect(alice.heal.counts.stampsRetiring == 1 && alice.heal.isParked(soon.id, now: 0))
        #expect(alice.heal.state(soon.id)?.parkedUntil == SpoolSession.minParkMilliseconds, "at least the shortest park")

        let later = try #require(Self.retiring(until: Fixture.wall + 2 * SpoolPlane.reconcileMilliseconds))
        let bob = Self.member(later)
        #expect(bob.mineRequests.count == 1, "a drain that ends later still mines")
        #expect(soon != later, "a drain that moves is a new table entry")
    }

    @Test func aRetiringScopeWhoseDrainIsLongOverParksForTheShortestPark() throws {
        let past = try #require(Self.retiring(until: Fixture.wall - 1))
        let alice = Self.member(past)
        #expect(alice.mineRequests.isEmpty && alice.heal.state(past.id)?.parkedUntil == SpoolSession.minParkMilliseconds)
    }
}
