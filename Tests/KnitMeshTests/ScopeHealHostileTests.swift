import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// What a spool or a member could send to break the heal loop (`ScopeSyncTest.kt` at knit-next `0832b8462`, P3a's
/// review, ADR 2026-11.adrq): a forged signature, a flood of junk events, deliveries and duplicates against the claims'
/// bound, a late frame, a `sentAt` at either end of `Int64`, and a digest flood. Each member keeps a real
/// ``MemoryCustodyStore``.
@Suite struct ScopeHealHostileTests {
    private typealias Fixture = ScopeFixture
    private let scope = ScopeFixture.scope(for: ScopeFixture.alice).id

    @Test func aCandidateRefusedAtItsSignatureIsQuarantinedAndNeverPulledAgain() throws {
        var lab = HealLab([Fixture.alice])
        var other = RawMember(lab.spool)
        lab.run(1)
        var forged = Fixture.dm(1, from: Fixture.bob, to: Fixture.alice)
        forged.wire.sig = try Fixture.carol.keys.signature(for: forged.wire.signed)
        other.push(forged)
        _ = lab.spool.take(lab.members[0].connection)
        let digest = ScopeCrypto.digest(of: [Fixture.sealed(forged).id.bytes])
        lab.spool.inject(
            SpoolSessionFixture.digest(scope, value: ScopeCrypto.digestBytes(digest), count: 1), into: lab.members[0].connection)
        lab.members[0].pump()
        lab.run(2)
        lab.advance(by: ScopeHeal.tickMilliseconds)
        lab.advance(by: ScopeHeal.tickMilliseconds)
        #expect(lab.members[0].pulls == [Fixture.sealed(forged).id], "pulled once")
        #expect(lab.members[0].heal.state(scope)?.invalid.contains(Fixture.sealed(forged).id) == true)
        #expect(lab.members[0].delivered.isEmpty)
    }

    @Test func tenThousandJunkEventsLeaveTheInvalidSetAloneAndTheClaimsBounded() {
        var lab = HealLab([Fixture.alice])
        lab.run(1)
        let alice = lab.members[0]
        for number in 0..<10_000 {
            let junk = fixtureBytes(120, seed: number) + withUnsafeBytes(of: UInt32(number).bigEndian, Array.init)
            let id = ScopeCrypto.blobId(of: junk)
            lab.spool.inject(SpoolEvent(scope: scope.bytes, blobId: id, data: junk).encoded, into: alice.connection)
            alice.pump()
            #expect(alice.session.claimCount(scope) <= SpoolSession.maxClaimsPerScope)
        }
        #expect(alice.heal.state(scope)?.invalid.isEmpty == true, "an event is never quarantined (C-9.3-4)")
        #expect(alice.session.claimCount(scope) == 0, "every claim was released")
        #expect(alice.delivered.isEmpty)
    }

    @Test func deliveriesAndDuplicatesKeepTheClaimsAtTheBound() {
        var lab = HealLab([Fixture.alice])
        lab.run(1)
        let alice = lab.members[0]
        // Old enough that custody refuses them, young enough that they are not late: each is delivered and accounted.
        let frames = (0..<600).map { Fixture.dm($0, from: Fixture.bob, to: Fixture.alice, sentAt: Fixture.wall - 30 * 3_600_000) }
        for frame in frames + frames.prefix(100) {
            let sealed = Fixture.sealed(frame)
            lab.spool.inject(SpoolEvent(scope: scope.bytes, blobId: sealed.id.bytes, data: sealed.blob).encoded, into: alice.connection)
            alice.pump()
            #expect(alice.session.claimCount(scope) <= SpoolSession.maxClaimsPerScope)
        }
        #expect(alice.delivered.count == 600 + 100 - alice.heal.counts.duplicates)
        #expect(alice.heal.state(scope)?.accounted.count == BoundedIDSet.defaultBound)
    }

    @Test func aLateFrameIsDeliveredAccountedAndNeverBridged() {
        var lab = HealLab([Fixture.alice])
        var other = RawMember(lab.spool)
        lab.run(1)
        let ahead = Fixture.dm(1, from: Fixture.bob, to: Fixture.alice, sentAt: Fixture.wall + 3_600_000)
        other.push(ahead)
        lab.run(3)
        #expect(lab.members[0].delivered.map(\.bridges) == [false])
        #expect(lab.members[0].heal.state(scope)?.accounted.contains(Fixture.sealed(ahead).id) == true)
        lab.expectQuiet(scope)
    }

    @Test func aSentAtAtEitherEndOfInt64NeverTraps() {
        var lab = HealLab([Fixture.alice, Fixture.bob])
        var other = RawMember(lab.spool)
        lab.run(1)
        let extremes = [
            Fixture.dm(1, from: Fixture.bob, to: Fixture.alice, sentAt: .max),
            Fixture.dm(2, from: Fixture.bob, to: Fixture.alice, sentAt: .min),
        ]
        for frame in extremes {
            other.push(frame)
        }
        lab.members[1].hold(extremes)
        lab.run(3)
        #expect(lab.members[0].delivered.allSatisfy { !$0.bridges })
        lab.expectQuiet(scope)
    }

    @Test func aDigestFloodListsAtMostOncePerInterval() {
        var lab = HealLab([Fixture.alice])
        lab.run(1)
        let alice = lab.members[0]
        alice.forgetSent()
        let seconds = 60
        for second in 1...seconds {
            lab.spool.inject(
                SpoolSessionFixture.digest(scope, value: ScopeCrypto.digestBytes(UInt64(second)), count: second), into: alice.connection)
            lab.advance(by: 1000)
        }
        #expect(alice.lists <= seconds / Int(ScopeHeal.healFloorMilliseconds / 1000) + 1)
        #expect(alice.lists > 0)
    }

    @Test func aLiveEventReplayingAnAccountedBlobAfterAReconnectYieldsNoCandidate() {
        var lab = HealLab([Fixture.alice])
        var other = RawMember(lab.spool)
        let alice = lab.members[0]
        lab.run(1)
        let old = Fixture.dm(1, from: Fixture.bob, to: Fixture.alice, sentAt: Fixture.wall - 30 * 3_600_000)
        other.push(old)
        lab.run(1)
        let sealed = Fixture.sealed(old)
        #expect(alice.delivered.count == 1 && alice.heal.state(scope)?.accounted.contains(sealed.id) == true)
        alice.reconnect()
        lab.spool.inject(SpoolEvent(scope: scope.bytes, blobId: sealed.id.bytes, data: sealed.blob).encoded, into: alice.connection)
        alice.pump()
        #expect(alice.delivered.count == 1)
        #expect(alice.heal.counts.replays == 1)
    }
}
