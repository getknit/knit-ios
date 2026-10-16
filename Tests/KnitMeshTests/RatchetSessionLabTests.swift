import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// knit-next's `SessionLabTest` (`mesh/lab/SessionLabTest.kt`, at `cbf2a487`) on two engines of this port with the switch
/// on (ADR 2026-10.5sk9, phase P5b): the both-initiate race in either order, the race's loser answering before its own
/// opener lands, a forced reset that heals without a storm while the other side's unacked DM is sealed again, the era a
/// reset retires read after it, and DMs a carrier brings from an era the reset retired. Each is checked by the lab's oracle:
/// both threads the same, and both sessions confirmed on one root and era with opposite roles (`MeshLab.kt:551-558`).
///
/// Kotlin's loser or receiver answers with a sealed tick, and since phase P5d so does this build: each DM's receipt is a
/// sealed `CTL_RECEIPT` that seals an epoch on the other's. The DM of each side's own that P5b's lab sent in its stead, once
/// before the oracle reads the sessions and once in the greeting, stays as one more round. Kotlin's lab runs on wall
/// clocks, so a reset there is always newer than the era it replaces; here the lab moves its clocks on a minute before
/// each one. The group cases are P6's, and `aGroupTickLostWithItsLinkIsSentAgainOnTheNextLink` is `@Ignore`d in knit-next
/// (#96).
@Suite struct RatchetSessionLabTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let dave = TestPeer(seed: 3)
    private static let minute: Int64 = 60_000

    /// Alice (0) and Bob (1), linked and acquainted: each pinned the other's profile, its prekey and the ratchet's bits.
    private func acquainted() throws -> EngineLab {
        let lab = EngineLab([try EngineFixture.ratcheting(alice, seed: 11), try EngineFixture.ratcheting(bob, seed: 12)])
        lab.link(0, 1)
        #expect(lab[0].stores.peers.peer(bob.nodeId)?.prekey != nil && lab[1].stores.peers.peer(alice.nodeId)?.prekey != nil)
        return lab
    }

    /// Node `from` sends `text` to node `to`, and answers its id.
    @discardableResult
    private func send(_ lab: EngineLab, _ from: Int, _ to: Int, _ text: String) throws -> String {
        let peer = lab[to].me.nodeId
        let record = try #require(lab[from].engine.sendDirectMessage(text, to: peer))
        lab.carry()
        return record.id
    }

    /// A DM each way, which confirms whatever session either side still waits on: P5b's stand-in for the sealed tick, which
    /// each receipt now is too.
    private func turnaround(_ lab: EngineLab, _ label: String) throws {
        try send(lab, 0, 1, "alice, \(label)")
        try send(lab, 1, 0, "bob, \(label)")
    }

    /// "hello" one way and "hi" the other, their sealed receipts, and one more round, converged.
    private func greeted() throws -> EngineLab {
        let lab = try acquainted()
        try send(lab, 0, 1, "hello")
        try send(lab, 1, 0, "hi")
        try turnaround(lab, "ticks")
        lab.expectConverged(0, 1, atLeast: 4, "greeted")
        return lab
    }

    /// Alice's reset toward Bob, a minute on, and the id our custody carries it under.
    private func aliceResets(_ lab: EngineLab) throws -> String {
        lab.advance(Self.minute)
        let custodied = Set(lab[0].stores.custody.liveIds(now: lab[0].clock.wallMilliseconds()))
        guard case .sent(_, reRooted: true) = lab[0].engine.sendRatchetReset(to: bob.nodeId) else {
            Issue.record("alice's reset went out")
            throw RatchetSessionSide.Unexpected()
        }
        return try #require(lab[0].stores.custody.liveIds(now: lab[0].clock.wallMilliseconds()).first { !custodied.contains($0) })
    }

    /// Both send a first DM while neither hears the other, and the inits cross in `aliceFirst`'s order.
    private func bothInitiate(aliceFirst: Bool) throws {
        let lab = try acquainted()
        lab.hold(from: 0, to: 1)
        lab.hold(from: 1, to: 0)
        try send(lab, 0, 1, "alice opens")
        try send(lab, 1, 0, "bob opens")
        let order = aliceFirst ? [(0, 1), (1, 0)] : [(1, 0), (0, 1)]
        for (from, to) in order {
            lab.release(from: from, to: to)
        }
        #expect(lab.thread(0, with: 1) == lab.thread(1, with: 0) && lab.thread(0, with: 1).count == 2)
        // A second round under whatever root won, then the oracle reads both sides' sessions.
        try turnaround(lab, "again")
        lab.expectConverged(0, 1, atLeast: 4, "after the race")
    }

    @Test func bothSidesInitiateAtOnceAndAlicesInitLandsFirst() throws {
        try bothInitiate(aliceFirst: true)
    }

    @Test func bothSidesInitiateAtOnceAndBobsInitLandsFirst() throws {
        try bothInitiate(aliceFirst: false)
    }

    /// Both initiate while apart, and the loser answers under the winner's root before its own opener reaches the winner:
    /// the winner confirms on that answer, and the loser's opener then lands on a confirmed session, read under the race's
    /// other root (#83).
    @Test func theLosersOpeningDmLandingAfterItsAnswersStillOpens() throws {
        let lab = try acquainted()
        let (winner, loser) = alice.nodeId < bob.nodeId ? (0, 1) : (1, 0)
        lab.hold(from: winner, to: loser)
        lab.hold(from: loser, to: winner)
        try send(lab, winner, loser, "winner opens")
        let opening = try send(lab, loser, winner, "loser opens")
        lab.release(from: winner, to: loser)
        #expect(lab.thread(loser, with: winner).contains { $0.hasSuffix("winner opens") })
        try send(lab, loser, winner, "loser answers")
        lab.release(from: loser, to: winner) { items in
            items.filter { $0.id != opening } + items.filter { $0.id == opening }
        }
        #expect(lab[winner].ratchetRecords(of: lab[loser].me).session?.confirmed == true, "the answer confirmed the winner")
        lab.expectConverged(winner, loser, atLeast: 3, "the late opener read")
    }

    /// Bob sends while apart, and Alice forces a reset while apart. On the merge Bob adopts the reset and seals his unacked
    /// DM again under the fresh session, Alice reads it, and Bob never resets back on the old-era copy custody served too.
    @Test func aForcedResetHealsAndTheOtherSidesUnackedDmsAreResealed() throws {
        let lab = try greeted()
        lab.unlink(0, 1)
        let apart = try send(lab, 1, 0, "sent while apart")
        _ = try aliceResets(lab)
        lab.link(0, 1)
        #expect(lab.thread(0, with: 1) == lab.thread(1, with: 0) && lab.thread(0, with: 1).count == 5)
        #expect(lab.seals(from: 1, to: 0, id: apart) == 2, "the reset reached Bob before Alice's receipt: sealed again once")
        try send(lab, 0, 1, "after the reset")
        try send(lab, 1, 0, "and back")
        lab.expectConverged(0, 1, atLeast: 7, "healed")
        #expect((lab[0].ratchetRecords(of: bob).session?.lastResetSentAt ?? 0) > 0, "alice sent the reset")
        #expect(lab[1].ratchetRecords(of: alice).session?.lastResetSentAt == 0, "bob never reset back")
        lab.advance(Self.minute)
        lab.expectCustodyAgrees(0, 1, resealed: [apart], from: 1, to: 0)
    }

    /// The #87 pinning (`tickAfterReset`): Alice reads Bob's while-apart DMs under the root her reset retired, and her next
    /// frame reaches Bob before her custodied reset does. That open must not confirm the replacement, so her next frame
    /// still carries the init Bob adopts the reset from. Kotlin's next frame is her sealed tick, and since P5d so is this
    /// build's: her sealed receipts for what she read, then the DM P5b's lab sent in their stead.
    private func aFrameAfterAResetReachesAPeerThatHasNotSeenIt(apart count: Int) throws {
        let lab = try greeted()
        lab.unlink(0, 1)
        let apart = try (1...count).map { try send(lab, 1, 0, "sent while apart \($0)") }
        let reset = try aliceResets(lab)

        lab.link(0, 1, holding: [(from: 0, to: 1), (from: 1, to: 0)])
        // Bob's serve walks custody newest first, so his DMs go oldest first: the first derives under the kept root.
        lab.release(from: 1, to: 0) { items in
            items.filter { $0.id.map { !apart.contains($0) } ?? true } + apart.flatMap { id in items.filter { $0.id == id } }
        }
        #expect(apart.allSatisfy { id in lab.thread(0, with: 1).contains { $0.hasPrefix(id) } }, "read under the root the reset retired")
        #expect(lab[0].ratchetRecords(of: bob).session?.confirmed == false, "and that open confirmed nothing (#87)")
        try send(lab, 0, 1, "read them")
        lab.release(from: 0, to: 1) { items in
            items.filter { $0.id != reset } + items.filter { $0.id == reset }
        }
        try turnaround(lab, "after the reset")
        lab.expectConverged(0, 1, atLeast: 4 + count + 3, "after the reset")
        #expect(lab[1].ratchetRecords(of: alice).session?.lastResetSentAt == 0, "bob never reset back")
    }

    @Test func aTickSealedAfterAResetStillReachesAPeerWhoHasNotSeenTheReset() throws {
        try aFrameAfterAResetReachesAPeerThatHasNotSeenIt(apart: 1)
    }

    @Test func aTickSealedAfterAResetStillReachesAPeerWhoHasNotSeenTheResetEvenAfterTwoDmsFromTheSameEpoch() throws {
        try aFrameAfterAResetReachesAPeerThatHasNotSeenIt(apart: 2)
    }

    /// #135 (knit-next ADR 2026-10.gcrd): Alice's DMs written while Bob was away ride her old era's epoch 2, and she resets,
    /// which restarts her numbering. Bob adopts the reset first and then reads them under the root it retired, so his chain
    /// for that number belongs to the old era. Alice's new era climbs back to the same number, and all of it still reaches
    /// Bob.
    @Test func oldEraDmsReadAfterTheResetNeverStrandTheNewEraAtTheirEpochNumber() throws {
        let lab = try greeted()
        lab.unlink(0, 1)
        let apart = try (1...3).map { try send(lab, 0, 1, "sent while apart \($0)") }
        let oldEpoch = try #require(lab[0].ratchetRecords(of: bob).session).sendEpoch
        #expect(oldEpoch >= 2, "precondition: the apart DMs sit past the epoch a reset restarts at")
        let reset = try aliceResets(lab)
        lab.link(0, 1, holding: [(from: 0, to: 1)])
        lab.release(from: 0, to: 1) { items in
            items.filter { $0.id == reset } + items.filter { $0.id != reset }
        }
        #expect(apart.allSatisfy { id in lab.thread(1, with: 0).contains { $0.hasPrefix(id) } })
        #expect(
            lab[0].ratchetRecords(of: bob).session?.root == lab[1].ratchetRecords(of: alice).session?.root, "bob read them after adopting")

        var turn = 0
        while try #require(lab[0].ratchetRecords(of: bob).session).sendEpoch <= oldEpoch {
            try turnaround(lab, "new era \(turn)")
            turn += 1
            guard turn <= 12 else {
                Issue.record("alice's new era never passed epoch \(oldEpoch)")
                return
            }
        }
        lab.expectConverged(0, 1, atLeast: 7 + 2 * turn, "past the old era's number")
        #expect(lab[1].ratchetRecords(of: alice).session?.lastResetSentAt == 0, "bob never reset back")
    }

    /// Alice sends three DMs to an absent Bob, which Dave carries, then forces a reset. When Bob returns the three are
    /// sealed under an era the reset retired, pre-era to Bob, so there is no reset storm, and they still reach him.
    @Test func dmsSealedUnderAnEraAResetRetiredStillArriveWithoutAStorm() throws {
        let lab = EngineLab([
            try EngineFixture.ratcheting(alice, seed: 11), try EngineFixture.ratcheting(bob, seed: 12), EngineFixture(dave, seed: 13),
        ])
        lab.link(0, 1)
        lab.link(0, 2)
        lab.link(1, 2)
        try send(lab, 0, 1, "hello")
        try send(lab, 1, 0, "hi")
        try turnaround(lab, "ticks")
        lab.expectConverged(0, 1, atLeast: 4, "greeted")

        lab.unlink(0, 1)
        lab.unlink(1, 2)
        let apart = try (1...3).map { try send(lab, 0, 1, "apart \($0)") }
        #expect(apart.allSatisfy { lab[2].stores.custody.contains($0) }, "dave carries the three")
        _ = try aliceResets(lab)
        lab.unlink(0, 2)

        lab.link(1, 2)
        #expect(apart.allSatisfy { id in lab.thread(1, with: 0).contains { $0.hasPrefix(id) } }, "dave's copies reached bob")
        lab.link(0, 1)
        #expect(lab.thread(0, with: 1) == lab.thread(1, with: 0) && lab.thread(1, with: 0).count == 7)
        try turnaround(lab, "back together")
        lab.expectConverged(0, 1, atLeast: 9, "back together")
        #expect(lab[1].ratchetRecords(of: alice).session?.lastResetSentAt == 0, "bob never reset back")
        #expect(lab[1].engine.dropped[.ratchetAeadFail] == nil && lab[1].engine.dropped[.ratchetNoSession] == nil)
    }
}
