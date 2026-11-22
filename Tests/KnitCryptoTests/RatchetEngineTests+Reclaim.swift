import KnitWire
import Testing

@testable import KnitCrypto

/// The race loser's reclaim (knit-next ADR 2026-10.4mjm, its rule C; ADR 2026-10.5sk9's P9a amendment), after
/// `RatchetEngineTest`'s rule C cases at knit-next `f018bc8ce`: the stamp, the swap on each rung, no swap inside the margin or
/// under a root that was confirmed and later replaced, and the stamp cleared at every other write of `prevRoot`. The session
/// layer judges the freshness (`RatchetSessions.sealedSinceLostRace`); here each open is told it.
extension RatchetEngineTests {
    /// Bob, the larger id, loses a race to Alice's init, sealed a second after his own. His opener stays unread at Alice,
    /// who then loses her rows, as a restore from a backup that predates the race does, and establishes from that opener
    /// as its responder: the one way a peer comes to seal under the init Bob lost.
    private func bobLostTheRaceAndAliceAnswersHisInit() throws -> (alice: RatchetSide, bob: RatchetSide) {
        let (alice, bob) = try RatchetSide.pair()
        #expect(alice.nodeId < bob.nodeId, "precondition: bob loses on node id")
        try bob.initiate(now: Self.now)
        try alice.initiate(now: Self.now + 1000)
        let opener = try bob.seal("bob opens", now: Self.now)
        #expect(try text(bob.open(alice.seal("alice opens", now: Self.now + 1000), now: Self.now + 1000)) == "alice opens")
        alice.wipe()
        #expect(try text(alice.open(opener, now: Self.now + 2000)) == "bob opens")
        return (alice, bob)
    }

    @Test func theRaceLoserStampsItsOwnInitAndTheWinnerStampsNothing() throws {
        let (alice, bob) = try RatchetSide.pair()
        try bob.initiate(now: Self.now)
        try alice.initiate(now: Self.now + 1000)
        let own = try #require(bob.session)
        let fromB = try bob.seal("from b", now: Self.now)
        #expect(try text(bob.open(alice.seal("from a", now: Self.now + 1000), now: Self.now + 1000)) == "from a")
        let lost = try #require(bob.session)
        #expect(lost.prevRoot == own.root && lost.prevRootWeAreInitiator)
        #expect(lost.prevRootOwnInitAt == Self.now, "his own init's stamp, our clock, read before the winner's took its place")
        #expect(lost.establishedAt == Self.now + 1000)

        #expect(try text(alice.open(fromB, now: Self.now + 1000)) == "from b")
        let won = try #require(alice.session)
        #expect(won.prevRoot == lost.prevRoot && won.prevRootOwnInitAt == nil, "the loser's root is never the winner's to reclaim")
    }

    /// The trace on the fresh derivation's rung: Alice answers Bob's init as its responder, sealed past the margin, and Bob
    /// moves back onto it as its confirmed initiator, the root he had adopted draining, the receive state of every other root
    /// purged, and the era effects taken from the frame.
    @Test func thePeerSealingUnderOurLostInitAsItsResponderMovesUsBackOntoIt() throws {
        let (alice, bob) = try bobLostTheRaceAndAliceAnswersHisInit()
        let lost = try #require(bob.session)
        let answer = try alice.seal("under your init", now: Self.now + 400_000)
        #expect(try text(bob.open(answer, now: Self.now + 400_000, sealedSinceLostRace: true)) == "under your init")
        let delta = try #require(bob.lastDelta)
        let reclaimed = try #require(bob.session)
        #expect(delta.reclaimed && delta.purgePeerRecvState && delta.openedUnderActiveRoot)
        let lostInit = try #require(lost.prevRoot)
        #expect(delta.keepRecvTag == RatchetCrypto.rootTag(lostInit))
        #expect(reclaimed.root == lost.prevRoot && reclaimed.root == alice.session?.root)
        #expect(reclaimed.confirmed && reclaimed.weAreInitiator && reclaimed.initEphPub == nil)
        #expect(reclaimed.establishedAt == Self.now, "restored from the stamp, so both sides hold one era")
        #expect(reclaimed.establishedAt == alice.session?.establishedAt)
        #expect(reclaimed.prevRoot == lost.root && !reclaimed.prevRootWeAreInitiator)
        #expect(reclaimed.prevRootExpiresAt == Self.now + 400_000 + RatchetEngine.previousRootMilliseconds)
        #expect(reclaimed.prevRootOwnInitAt == nil)
        #expect(reclaimed.peerInitEphPub == lost.peerInitEphPub, "the winning init stays the anchor")
        #expect(reclaimed.peerBaseEpoch == answer.header.se && reclaimed.highestPeAcked == answer.header.pe)
        #expect(reclaimed.sendChainKey == nil && reclaimed.lastResetSentAt == lost.lastResetSentAt)
        #expect(Set(bob.rows.chains.keys.map(\.rootTag)) == [RatchetCrypto.rootTag(reclaimed.root)])

        // Bob's next frame opens a new epoch under the reclaimed root, his numbering monotone, and Alice reads it.
        let next = try bob.seal("back on my init", now: Self.now + 400_000)
        #expect(next.header.se == lost.sendEpoch + 1)
        #expect(try text(alice.open(next, now: Self.now + 400_000)) == "back on my init")
        #expect(try text(bob.open(alice.seal("both ways", now: Self.now + 400_000), now: Self.now + 400_000)) == "both ways")
    }

    /// A first answer read inside the margin opens read-only and moves nothing, and a later one of the same epoch, on the
    /// live chain the first stored, reclaims: the freshness is judged on every rung (knit-next ADR 2026-10.4mjm).
    @Test func anAnswerInsideTheMarginIsReadReadOnlyAndALaterOneReclaimsOnTheLiveChain() throws {
        let (alice, bob) = try bobLostTheRaceAndAliceAnswersHisInit()
        let lost = try #require(bob.session)
        #expect(try text(bob.open(alice.seal("inside", now: Self.now + 2000), now: Self.now + 2000)) == "inside")
        #expect(bob.session == lost, "read under the drained root, read-only")
        #expect(try #require(bob.lastDelta).reclaimed == false)

        #expect(
            try text(bob.open(alice.seal("later", now: Self.now + 400_000), now: Self.now + 400_000, sealedSinceLostRace: true)) == "later")
        let delta = try #require(bob.lastDelta)
        #expect(delta.reclaimed && delta.recvEpoch?.next == 2, "on the chain the read-only open stored")
        #expect(bob.session?.root == lost.prevRoot && bob.session?.weAreInitiator == true)
        let kept = RatchetCrypto.rootTag(try #require(lost.prevRoot))
        #expect(bob.rows.chains.keys.allSatisfy { $0.rootTag == kept }, "the reclaimed root's chain survived the purge")
    }

    /// The same on the skipped key's rung: the read-only open of a later index banked the keys, and the reclaiming frame
    /// spends one. The other survives the purge, the reclaimed root's, and its frame still opens.
    @Test func aLaterAnswerReclaimsOnASkippedKey() throws {
        let (alice, bob) = try bobLostTheRaceAndAliceAnswersHisInit()
        let lost = try #require(bob.session)
        let early = try alice.seal("early", now: Self.now + 2000)
        let middle = try alice.seal("middle", now: Self.now + 2000)
        #expect(try text(bob.open(alice.seal("overtook it", now: Self.now + 2000), now: Self.now + 2000)) == "overtook it")
        #expect(bob.session == lost)
        #expect(try text(bob.open(early, now: Self.now + 400_000, sealedSinceLostRace: true)) == "early")
        let delta = try #require(bob.lastDelta)
        let lostInit = try #require(lost.prevRoot)
        #expect(delta.reclaimed && delta.consumedSkippedTag == RatchetCrypto.rootTag(lostInit))
        #expect(bob.session?.root == lost.prevRoot && bob.session?.confirmed == true && bob.session?.weAreInitiator == true)
        #expect(bob.session?.peerBaseEpoch == early.header.se, "the era effects ran on the skipped key's rung too")
        #expect(try text(bob.open(middle, now: Self.now + 400_000)) == "middle", "its skipped key survived the purge")
    }

    /// The reclaim restarts `highestPeAcked` with the DH base: left at the abandoned era's ack, the retired-base gate would
    /// read the reclaimed era's `EPOCH_GONE`s as doomed (`RatchetEngine.kt:965` at `f018bc8ce`).
    @Test func theReclaimRestartsTheAckWithTheBase() throws {
        let (alice, bob) = try RatchetSide.pair()
        try bob.initiate(now: Self.now)
        try alice.initiate(now: Self.now + 1000)
        let opener = try bob.seal("bob opens", now: Self.now)
        #expect(try text(bob.open(alice.seal("alice opens", now: Self.now + 1000), now: Self.now + 1000)) == "alice opens")
        #expect(try text(alice.open(bob.seal("under the winner", now: Self.now + 1000), now: Self.now + 1000)) == "under the winner")
        #expect(try text(bob.open(alice.seal("acked", now: Self.now + 1000), now: Self.now + 1000)) == "acked")
        #expect(try #require(bob.session).highestPeAcked == 2, "precondition: alice sealed against bob's second epoch")

        alice.wipe()
        #expect(try text(alice.open(opener, now: Self.now + 2000)) == "bob opens")
        let answer = try alice.seal("under your init", now: Self.now + 400_000)
        #expect(answer.header.pe == 1)
        #expect(try text(bob.open(answer, now: Self.now + 400_000, sealedSinceLostRace: true)) == "under your init")
        #expect(try #require(bob.lastDelta).reclaimed)
        #expect(try #require(bob.session).highestPeAcked == 1, "the reclaimed era's ack, not the left era's")
    }

    /// The pure rule (`reclaimsPrevRoot`): our own init in the slot, the peer its responder, and a frame sealed since.
    @Test func onlyOurOwnInitLostToARaceAnsweredSinceReclaims() {
        let context = { (fresh: Bool) in
            RatchetEngine.OpenContext(
                selfNodeId: .repeating("a"),
                peerId: .repeating("b"),
                session: nil,
                recvEpochs: [],
                skippedKeys: [],
                ownBasePrivateKey: nil,
                identity: IdentityKeys.generate(),
                peerIdentity: IdentityKeys.generate().bundle,
                prekeyForInit: nil,
                sealedSinceLostRace: fresh
            )
        }
        var session = RatchetEngine.SessionState(
            peerId: .repeating("b"),
            confirmed: true,
            weAreInitiator: false,
            root: [1],
            prevRoot: [2],
            prevRootWeAreInitiator: true,
            prevRootExpiresAt: Self.now,
            prevRootOwnInitAt: 5,
            establishedAt: 6
        )
        #expect(RatchetEngine.reclaimsPreviousRoot(session, context(true)) == 5)
        #expect(RatchetEngine.reclaimsPreviousRoot(session, context(false)) == nil, "inside the margin")
        session.prevRootWeAreInitiator = false
        #expect(RatchetEngine.reclaimsPreviousRoot(session, context(true)) == nil, "the peer was that root's initiator")
        session.prevRootWeAreInitiator = true
        session.prevRootOwnInitAt = nil
        #expect(RatchetEngine.reclaimsPreviousRoot(session, context(true)) == nil, "no init of ours lost to a race")
    }

    /// A replacement adopted while the stamp stands clears it (`RatchetEngine.kt:708-710` at `f018bc8ce`): the root it
    /// named is no longer the slot's.
    @Test func aReplacementClearsTheStamp() throws {
        let (alice, bob) = try bobLostTheRaceAndAliceAnswersHisInit()
        let reset = try alice.reset(now: Self.now + 3000)
        #expect(try text(bob.open(reset, now: Self.now + 3000, resetRequested: true)) == "reset")
        let replaced = try #require(bob.session)
        #expect(replaced.root == alice.session?.root && replaced.prevRootOwnInitAt == nil)
    }

    /// A drain frame of the era Bob reclaimed, confirmed and then left for Alice's reset, never swaps him back into it, even
    /// told it is fresh: our role there was initiator, and no stamp names it.
    @Test func aDrainFrameOfAnEraConfirmedAndLaterReplacedNeverSwapsUsBack() throws {
        let (alice, bob) = try bobLostTheRaceAndAliceAnswersHisInit()
        #expect(
            try text(bob.open(alice.seal("answer", now: Self.now + 400_000), now: Self.now + 400_000, sealedSinceLostRace: true))
                == "answer")
        #expect(try #require(bob.lastDelta).reclaimed)
        let drained = try alice.seal("sealed before the reset", now: Self.now + 400_000)
        let reset = try alice.reset(now: Self.now + 500_000)
        #expect(try text(bob.open(reset, now: Self.now + 500_000, resetRequested: true)) == "reset")
        let replaced = try #require(bob.session)
        #expect(replaced.prevRootWeAreInitiator && replaced.prevRootOwnInitAt == nil)

        #expect(try text(bob.open(drained, now: Self.now + 600_000, sealedSinceLostRace: true)) == "sealed before the reset")
        #expect(try #require(bob.lastDelta).reclaimed == false)
        #expect(bob.session?.root == replaced.root, "read under the drain, never swapped back")
    }

    /// The drain running out clears the stamp with the root it named (`retirePrevRoot`, `RatchetEngine.kt:1011-1019` at
    /// `f018bc8ce`).
    @Test func theDrainRunningOutClearsTheStamp() throws {
        let (alice, bob) = try RatchetSide.pair()
        try bob.initiate(now: Self.now)
        try alice.initiate(now: Self.now + 1000)
        #expect(try text(bob.open(alice.seal("alice opens", now: Self.now + 1000), now: Self.now + 1000)) == "alice opens")
        #expect(try #require(bob.session).prevRootOwnInitAt != nil)
        let later = Self.now + 1000 + RatchetEngine.previousRootMilliseconds
        #expect(try text(bob.open(alice.seal("two days on", now: later), now: later)) == "two days on")
        let retired = try #require(bob.session)
        #expect(retired.prevRoot == nil && retired.prevRootExpiresAt == 0 && retired.prevRootOwnInitAt == nil)
    }

    /// A frame our own custody hands back at start may reclaim too (ADR 2026-10.5sk9's P9a amendment): the stamp guards
    /// itself, since every other write of `prevRoot` clears it, so a stamp still held means no era changed since the race
    /// was lost, and a responder's frame carries no init for the start's guard to hold back.
    @Test func aFrameReplayedAtStartReclaimsToo() throws {
        let (alice, bob) = try bobLostTheRaceAndAliceAnswersHisInit()
        let answer = try alice.seal("under your init", now: Self.now + 400_000)
        #expect(try text(bob.open(answer, now: Self.now + 400_000, allowEraChange: false, sealedSinceLostRace: true)) == "under your init")
        #expect(try #require(bob.lastDelta).reclaimed)
        #expect(bob.session?.root == alice.session?.root)
    }
}
