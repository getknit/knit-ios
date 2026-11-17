import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Two members of one DM scope over one ``FakeSpool``, each with its own ``MemoryCustodyStore`` under `CustodyRules`
/// deciding what is kept, driven tick by tick (`ScopeSyncTest.kt` at knit-next `0832b8462`, the text cases; ADR
/// 2026-11.adrq). Each case ends with every member's local fold equal to the spool's digest and a round that sends no
/// `list`, unless it says otherwise.
@Suite struct ScopeHealConvergenceTests {
    private typealias Fixture = ScopeFixture
    private let scope = ScopeFixture.scope(for: ScopeFixture.alice).id

    private func retiringScopes(_ member: TestPeer) -> [SpoolScope] {
        [Fixture.scope(for: member, retiring: true)]
    }

    private func held(_ member: HealMember, _ frame: TestFrame, at now: SpoolNow) -> Bool {
        member.custody.frame(frame.envelope.id, now: now.wall) != nil
    }

    @Test func aMemberHoldingNothingGetsEveryFrameAndEachBlobIsPushedOnce() {
        var lab = HealLab([Fixture.alice, Fixture.bob])
        let frames = [Fixture.dm(1), Fixture.dm(2, from: Fixture.bob, to: Fixture.alice), Fixture.dm(3)]
        lab.members[0].hold(frames)
        lab.run(4)

        let ids = frames.map { Fixture.sealed($0).id }
        #expect(Set(lab.spool.liveIds(scope)) == Set(ids))
        #expect(lab.spool.stored.count == ids.count, "the spool stored each blob once")
        #expect(lab.members[0].pushes.count == ids.count && lab.members[1].pushes.isEmpty, "only the member that held them pushed")
        #expect(frames.allSatisfy { held(lab.members[1], $0, at: lab.now) })
        #expect(lab.members[1].delivered.count == ids.count, "each delivered once")
        lab.expectQuiet(scope)
    }

    @Test func aSpoolClaimingAMaxBlobBelowOursStillConverges() {
        let limits = SpoolLimits(maxBlob: 4096, maxRecord: 66_048, maxScopes: 64, maxPull: 64, maxFramesCap: 400, maxTtlMs: 604_800_000)
        var lab = HealLab([Fixture.alice, Fixture.bob], spool: FakeSpool(limits: limits, now: Fixture.wall))
        lab.members[0].hold([Fixture.dm(1), Fixture.dm(2, from: Fixture.bob, to: Fixture.alice)])
        lab.run(4)
        #expect(lab.spool.stored.count == 2)
        lab.expectQuiet(scope)
    }

    @Test func membersConvergeWhenOnesStampSearchesAreCancelledTwice() {
        var lab = HealLab([Fixture.alice, Fixture.bob], spool: FakeSpool(powBits: 8, now: Fixture.wall), manualMiner: Fixture.alice)
        let alice = lab.members[0]
        alice.hold([Fixture.dm(1)])
        var cancelled = 0
        for _ in 0..<(3 * SpoolSession.minParkMilliseconds / ScopeHeal.healFloorMilliseconds) {
            for request in alice.pendingMining {
                if cancelled < 2 {
                    cancelled += 1
                    alice.failMining(request)
                } else {
                    alice.pendingMining.removeAll { $0 == request }
                    alice.mine(request)
                }
            }
            lab.advance(by: ScopeHeal.healFloorMilliseconds)
        }
        #expect(cancelled == 2)
        #expect(lab.spool.liveIds(scope) == [Fixture.sealed(Fixture.dm(1)).id])
        lab.expectQuiet(scope)
    }

    @Test func bothMembersHoldingFramesFillEachOther() {
        var lab = HealLab([Fixture.alice, Fixture.bob])
        lab.members[0].hold([Fixture.dm(1)])
        lab.members[1].hold([Fixture.dm(2, from: Fixture.bob, to: Fixture.alice), Fixture.dm(1)])
        lab.run(4)
        #expect(lab.spool.stored.count == 2)
        #expect(
            Set(lab.members[0].pushes + lab.members[1].pushes).count == lab.members[0].pushes.count + lab.members[1].pushes.count,
            "no blob pushed twice")
        lab.expectQuiet(scope)
    }

    @Test func the201stFrameFromOneSenderEvictedByCustodysQuotaIsAccounted() {
        var lab = HealLab([Fixture.alice, Fixture.bob])
        let first = Fixture.dm(0, sentAt: Fixture.wall)
        lab.members[0].hold([first])
        lab.run(3)
        // Two hundred newer frames: custody keeps the newest 200 per sender, everywhere, so the first leaves both.
        let newer = (1...200).map { Fixture.dm($0, sentAt: Fixture.wall + Int64($0)) }
        lab.members[0].hold(newer)
        lab.run(8)

        #expect(lab.spool.liveIds(scope).count == 201)
        #expect(!held(lab.members[0], first, at: lab.now) && !held(lab.members[1], first, at: lab.now))
        for member in lab.members {
            #expect(member.heal.state(scope)?.accounted.contains(Fixture.sealed(first).id) == true)
        }
        #expect(lab.members[0].pulls == [Fixture.sealed(first).id], "its pusher re-pulled it once")
        #expect(lab.members[1].pulls.isEmpty, "the member that took it on this connection accounts it without a pull")
        lab.expectQuiet(scope)
    }

    @Test func custodysDayPassingWhileTheSpoolKeepsTheBlobRePullsItOnceThenAccountsIt() {
        var lab = HealLab([Fixture.alice, Fixture.bob])
        let frame = Fixture.dm(1)
        lab.members[0].hold([frame])
        lab.run(3)
        lab.advance(by: 25 * 3_600_000)
        lab.run(4)

        let id = Fixture.sealed(frame).id
        #expect(lab.spool.liveIds(scope) == [id], "the spool keeps it 48 h")
        #expect(lab.members[0].pulls == [id], "pulled once, refused by custody as dead on arrival")
        #expect(lab.members.allSatisfy { $0.heal.state(scope)?.accounted.contains(id) == true })
        lab.expectQuiet(scope)
        #expect(lab.members[0].pulls.isEmpty, "and never again")
    }

    @Test func theSpoolsExpiryPrunesAnAccountedId() {
        var lab = HealLab([Fixture.alice, Fixture.bob])
        lab.members[0].hold([Fixture.dm(1)])
        lab.run(3)
        lab.advance(by: 25 * 3_600_000)
        lab.run(3)
        lab.advance(by: 24 * 3_600_000)
        lab.run(3)

        #expect(lab.spool.liveIds(scope).isEmpty)
        #expect(lab.members.allSatisfy { $0.heal.state(scope)?.accounted.isEmpty == true }, "pruned once the listing stopped naming it")
        lab.expectQuiet(scope)
    }

    @Test func aDigestLandingDuringTheListIsKeptAndTheNextRoundListsAgain() {
        var lab = HealLab([Fixture.alice])
        var other = RawMember(lab.spool)
        let alice = lab.members[0]
        alice.hold([Fixture.dm(1)])
        lab.run(2)
        other.push(Fixture.dm(2, from: Fixture.bob, to: Fixture.alice))
        alice.pump()
        other.push(Fixture.dm(3, from: Fixture.bob, to: Fixture.alice))
        _ = lab.spool.take(alice.connection)
        let fourth = Fixture.dm(4, from: Fixture.bob, to: Fixture.alice)
        let earlier = [
            Fixture.dm(1), Fixture.dm(2, from: Fixture.bob, to: Fixture.alice), Fixture.dm(3, from: Fixture.bob, to: Fixture.alice),
        ]
        let landed = HealLab.fold((earlier + [fourth]).map { Fixture.sealed($0).id })

        alice.beginRound(at: SpoolNow(monotonic: lab.now.monotonic + 5000, wall: lab.now.wall + 5000))
        lab.spool.inject(SpoolSessionFixture.digest(scope, value: ScopeCrypto.digestBytes(landed), count: 4), into: alice.connection)
        alice.forgetSent()
        alice.pump()
        #expect(alice.lists == 1)
        #expect(alice.anchor(scope) == landed, "the newer digest survives the round")

        other.push(fourth)
        _ = lab.spool.take(alice.connection)
        alice.forgetSent()
        alice.step(at: SpoolNow(monotonic: lab.now.monotonic + 10_000, wall: lab.now.wall + 10_000))
        #expect(alice.lists == 1, "the next round lists again")
        #expect(alice.pulls == [Fixture.sealed(fourth).id])
        #expect(alice.heal.localFold(scope) != nil)
    }

    @Test func anEventAndAPullOfOneBlobDeliverItOnce() {
        var lab = HealLab([Fixture.alice])
        var other = RawMember(lab.spool)
        let alice = lab.members[0]
        lab.run(1)
        let frame = Fixture.dm(1, from: Fixture.bob, to: Fixture.alice)
        other.push(frame)
        let event = lab.spool.take(alice.connection)
        // The spool's digest brings the listing; the pull it starts races the event, which lands after.
        let digest = ScopeCrypto.digest(of: [Fixture.sealed(frame).id.bytes])
        lab.spool.inject(SpoolSessionFixture.digest(scope, value: ScopeCrypto.digestBytes(digest), count: 1), into: alice.connection)
        alice.pump()
        lab.run(1)
        for case .record(let bytes) in event {
            alice.session.receive(bytes)
        }
        alice.pump()

        #expect(alice.pulls == [Fixture.sealed(frame).id])
        #expect(alice.delivered.count == 1)
        #expect(alice.heal.counts.duplicates == 1)
    }

    @Test func aFreshHealAfterARestartRePullsOnceThenGoesQuiet() {
        var lab = HealLab([Fixture.alice, Fixture.bob])
        let frame = Fixture.dm(1)
        lab.members[0].hold([frame])
        lab.run(3)
        lab.advance(by: 25 * 3_600_000)
        lab.run(3)
        // A cold launch: custody persists, the accounted set does not (C-9.6-4).
        let restarted = HealMember(
            Fixture.alice, spool: lab.spool, scopes: [Fixture.scope(for: Fixture.alice)], custody: lab.members[0].custody, at: lab.now)
        lab.spool.drop(lab.members[0].connection)
        lab.members[0] = restarted
        lab.run(3)
        #expect(restarted.pulls == [Fixture.sealed(frame).id], "re-pulled once")
        lab.expectQuiet(scope)
    }

    @Test func aListingThatNamesAnUnpushableFramePutsItBackInTheFold() {
        var lab = HealLab([Fixture.alice], scopes: retiringScopes)
        let alice = lab.members[0]
        let frame = Fixture.dm(1)
        alice.hold([frame])
        lab.run(3)
        var other = RawMember(lab.spool)
        other.push(frame)
        _ = lab.spool.take(alice.connection)
        let digest = HealLab.fold([Fixture.sealed(frame).id])
        lab.spool.inject(SpoolSessionFixture.digest(scope, value: ScopeCrypto.digestBytes(digest), count: 1), into: alice.connection)
        alice.pump()
        lab.run(2)
        #expect(alice.heal.state(scope)?.unpushable.isEmpty == true)
        lab.expectQuiet(scope)
    }

    @Test func aDeliveredEventForAnUnpushableFramePutsItBackInTheFold() {
        var lab = HealLab([Fixture.alice], scopes: retiringScopes)
        let alice = lab.members[0]
        let frame = Fixture.dm(1)
        alice.hold([frame])
        lab.run(3)
        #expect(alice.heal.state(scope)?.unpushable.contains(Fixture.sealed(frame).id) == true)
        var other = RawMember(lab.spool)
        other.push(frame)
        lab.run(3)
        #expect(alice.heal.state(scope)?.unpushable.isEmpty == true)
        lab.expectQuiet(scope)
    }

    @Test func aRetiringScopesHeldFramesAreNeverPushedAndItStopsListing() {
        var lab = HealLab([Fixture.alice, Fixture.bob], scopes: retiringScopes)
        lab.members[0].hold([Fixture.dm(1), Fixture.dm(2, from: Fixture.bob, to: Fixture.alice)])
        lab.run(3)
        #expect(lab.spool.stored.isEmpty, "a retiring scope is never refilled (C-3.1-3)")
        #expect(lab.members[0].heal.state(scope)?.unpushable.count == 2)
        lab.expectQuiet(scope)
    }

    @Test func aTombstonedHeldFrameLeavesTheFold() {
        let spool = FakeSpool(
            limits: SpoolLimits(maxBlob: 65_536, maxRecord: 66_048, maxScopes: 64, maxPull: 64, maxFramesCap: 2, maxTtlMs: 604_800_000),
            now: Fixture.wall)
        var lab = HealLab([Fixture.alice], spool: spool)
        var other = RawMember(spool)
        let first = Fixture.dm(1, from: Fixture.bob, to: Fixture.alice)
        other.push(first)
        other.push(Fixture.dm(2, from: Fixture.bob, to: Fixture.alice))
        other.push(Fixture.dm(3, from: Fixture.bob, to: Fixture.alice))
        #expect(spool.tombstones(scope) == [Fixture.sealed(first).id])
        lab.members[0].hold([first])
        lab.run(4)
        #expect(lab.members[0].pushes.isEmpty)
        #expect(lab.members[0].heal.state(scope)?.unpushable.contains(Fixture.sealed(first).id) == true)
        lab.expectQuiet(scope)
    }

    @Test func aValidFrameOfSixtyKilobytesCustodyWillNotKeepIsAccounted() {
        var lab = HealLab([Fixture.alice])
        var other = RawMember(lab.spool)
        lab.run(1)
        let big = Fixture.dm(1, from: Fixture.bob, to: Fixture.alice, padding: 62_000)
        let sealed = Fixture.sealed(big)
        #expect(big.wire.signed.count > CustodyLimits().maxSignedBytes && sealed.blob.count <= ScopeFrames.maxBlob)
        other.push(big)
        lab.run(3)
        #expect(lab.members[0].delivered.count == 1)
        #expect(lab.members[0].heal.state(scope)?.accounted.contains(sealed.id) == true)
        lab.expectQuiet(scope)
    }

    @Test func ourOwnFlaggedResetIsNeverPushed() {
        var lab = HealLab([Fixture.alice, Fixture.bob])
        let reset = Fixture.dm(1, reset: true)
        lab.members[0].hold([reset, Fixture.dm(2)])
        lab.run(4)
        #expect(lab.spool.liveIds(scope) == [Fixture.sealed(Fixture.dm(2)).id])
        #expect(!lab.members[0].pushes.contains(Fixture.sealed(reset).id))
        lab.expectQuiet(scope)
    }
}

extension HealLab {
    /// Every member's local fold of `scope` is the spool's digest, and a timed round lists nothing.
    mutating func expectQuiet(_ scope: SpoolID, sourceLocation: SourceLocation = #_sourceLocation) {
        run(2)
        for member in members {
            #expect(
                member.heal.localFold(scope) == spoolDigest(scope), "\(member.identity.nodeId) folds the spool",
                sourceLocation: sourceLocation)
            member.forgetSent()
        }
        advance(by: ScopeHeal.tickMilliseconds)
        run(2)
        for member in members {
            #expect(member.lists == 0, "\(member.identity.nodeId) lists after converging", sourceLocation: sourceLocation)
            #expect(member.heal.localFold(scope) == spoolDigest(scope), sourceLocation: sourceLocation)
        }
    }
    /// The XOR fold of `ids` (§6.3).
    static func fold(_ ids: [SpoolID]) -> UInt64 {
        ScopeCrypto.digest(of: ids.map(\.bytes))
    }
}
