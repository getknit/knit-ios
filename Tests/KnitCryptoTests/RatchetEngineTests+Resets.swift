import KnitWire
import Testing

@testable import KnitCrypto

/// Resets, wipes and replacements: a reset of ours keeps the old root draining and restarts our numbering, and an init
/// that replaces a resolved session is adopted only when it may be.
extension RatchetEngineTests {
    /// What `FLAG_RESET` exempts from the remnant guard it also keeps out of the read-only remnant candidate: a reset is
    /// adopted or refused, never read without adoption, or its re-seal would run under the root it asks us to leave. One
    /// whose init is older than the session we confirmed stays refused.
    @Test func aStaleFlaggedResetIsRefusedNeverReadWithoutAdoption() throws {
        let (alice, bob) = try RatchetSide.pair()
        let staleReset = try bob.reset(now: Self.now)
        try alice.initiate(now: Self.now + 10_000)
        _ = try bob.open(alice.seal("from a", now: Self.now + 10_000), now: Self.now + 10_000)
        _ = try alice.open(bob.seal("reply under the winner", now: Self.now + 10_000), now: Self.now + 10_000)
        #expect(try #require(alice.session).confirmed)
        #expect(try #require(alice.session).peerInitEphPub == nil)
        let root = try #require(alice.session).root

        #expect(try alice.open(staleReset, now: Self.now + 20_000, resetRequested: true).failure == .aeadFail)
        #expect(try #require(alice.session).root == root)
    }

    @Test func anExplicitResetIsAdoptedEvenByTheUnanchoredRaceWinner() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        try bob.initiate(now: Self.now + 5000)

        // alice wins the race on node id and confirms without ever reading bob's init, so she holds no anchor: the state
        // the race-remnant guard exists for.
        _ = try bob.open(alice.seal("from a", now: Self.now), now: Self.now)
        _ = try alice.open(bob.seal("reply under the winner", now: Self.now), now: Self.now)
        #expect(try #require(alice.session).confirmed)
        #expect(try #require(alice.session).peerInitEphPub == nil)
        #expect(alice.nodeId < bob.nodeId, "precondition: b is the higher node id the guard refuses")

        // bob loses his state and asks to start over. Unflagged this would be read and never adopted, as a re-served race
        // remnant is; flagged it must be adopted, or bob could never recover from his own side and only alice's 6 h
        // heuristic would clear it, the one-way blackout knit-next ADR 024 was opened for.
        bob.wipe()
        try bob.initiate(now: Self.now + 600_000)
        let outcome = try alice.open(bob.seal("re-establish", now: Self.now + 600_000), now: Self.now + 600_000, resetRequested: true)

        #expect(try text(outcome) == "re-establish")
        #expect(try !#require(alice.session).weAreInitiator, "adopting a reset makes us the responder")
        #expect(try #require(alice.session).root == #require(bob.session).root)
    }

    @Test func adoptingAResetAnchorsItSoItsOwnReServesAreInert() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        try bob.initiate(now: Self.now + 5000)
        _ = try bob.open(alice.seal("from a", now: Self.now), now: Self.now)
        _ = try alice.open(bob.seal("reply under the winner", now: Self.now), now: Self.now)

        bob.wipe()
        try bob.initiate(now: Self.now + 600_000)
        let reset = try bob.seal("re-establish", now: Self.now + 600_000)
        _ = try alice.open(reset, now: Self.now + 600_000, resetRequested: true)
        let adopted = try #require(alice.session).root

        // Custody re-serves the reset for a whole TTL. The ephemeral anchored on adoption makes every copy inert, so the
        // exemption cannot become a re-rooting loop.
        #expect(try alice.open(reset, now: Self.now + 900_000, resetRequested: true).failure == .duplicate)
        #expect(try #require(alice.session).root == adopted)
    }

    @Test func theSideThatAdoptedAReplacementCanStillSendBack() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("hello", now: Self.now), now: Self.now)
        _ = try alice.open(bob.seal("hi", now: Self.now), now: Self.now)

        // alice initiates again (a reset): bob must adopt it, which drops his peer base before the fresh derivation takes
        // her new epoch 1 as its base.
        try alice.initiate(now: Self.now + 600_000)
        #expect(try text(bob.open(alice.seal("re-established", now: Self.now + 600_000), now: Self.now + 600_000)) == "re-established")

        // bob, the adopter, answers on that base (Kotlin's comment here says pe = 0; the frame carries pe = 1, and no init).
        let back = try alice.open(bob.seal("reply after adopting", now: Self.now + 601_000), now: Self.now + 601_000)
        #expect(try text(back) == "reply after adopting")
    }

    @Test func aWipedPeersReInitReplacesTheSessionAndPurgesStaleRecvState() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("before the wipe", now: Self.now), now: Self.now)
        _ = try alice.open(bob.seal("reply", now: Self.now), now: Self.now)

        alice.wipe()
        try alice.initiate(now: Self.now + 10_000)
        let reborn = try alice.seal("after the wipe", now: Self.now + 10_000)

        #expect(try text(bob.open(reborn, now: Self.now + 10_000)) == "after the wipe")
        #expect(try #require(bob.lastDelta).purgePeerRecvState)
        #expect(try #require(bob.session).establishedAt == Self.now + 10_000)
        #expect(bob.recvNumbers == [1])

        // bob's next send reaches the reborn alice; his own numbering never restarted.
        let toReborn = try bob.seal("welcome back", now: Self.now + 10_000)
        #expect(toReborn.header.se >= 2)
        #expect(try text(alice.open(toReborn, now: Self.now + 10_000)) == "welcome back")
    }

    @Test func oldEraFramesDrainViaPrevRootWhenEpochNumbersDoNotCollide() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("establish", now: Self.now), now: Self.now)
        _ = try alice.seal("burn epoch 1", now: Self.now)
        let oldEra = try alice.seal("old era, epoch 2", now: Self.now, force: true)

        alice.wipe()
        try alice.initiate(now: Self.now + 10_000)
        _ = try bob.open(alice.seal("new era", now: Self.now + 10_000), now: Self.now + 10_000)

        // The frame before the wipe is epoch 2, the new era's epoch 1: with the receive state purged, a fresh derivation
        // fails under the new root and succeeds under the draining one.
        #expect(try text(bob.open(oldEra, now: Self.now + 10_000)) == "old era, epoch 2")
    }

    @Test func oldEraFramesWhoseEpochNumberCollidesFailBenignly() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        let old0 = try alice.seal("old era, epoch 1, n=0", now: Self.now)
        let old1 = try alice.seal("old era, epoch 1, n=1", now: Self.now)

        alice.wipe()
        try alice.initiate(now: Self.now + 10_000)
        _ = try bob.open(alice.seal("new era, epoch 1", now: Self.now + 10_000), now: Self.now + 10_000)

        // bob never held the old era's root (none of its frames reached him before the wipe), so nothing can open them: an
        // index below the new chain's cursor reads as a duplicate, one at or above it fails the AEAD. Benign by design:
        // the exists-gate skips anything delivered before the wipe, and the reset path re-seals the rest. (Had bob held
        // it as prevRoot, both would drain: see the #135 cases.)
        #expect(try bob.open(old0, now: Self.now + 10_000).failure == .duplicate)
        #expect(try bob.open(old1, now: Self.now + 10_000).failure == .aeadFail)
    }

    /// Why the read-only remnant candidate records nothing. A resetter's follow-ups carry its reset's init without the
    /// flag, and to a session we initiated whose peer never sent an init that is exactly a race remnant: read, not
    /// adopted. Had the read anchored the init's ephemeral, the flagged reset itself, the same ephemeral, would then open
    /// as an inert re-serve on the skipped key its follow-up stored, never adopted, and we would sit on the root the peer
    /// had left.
    @Test func anUnanchoredWinnerThatReadAResetsUnflaggedFollowerStillAdoptsTheReset() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("hello", now: Self.now), now: Self.now)
        _ = try bob.seal("never delivered", now: Self.now) // bob's epoch 1: alice holds no chain for the number his reset reuses
        _ = try alice.open(bob.seal("hi", now: Self.now, force: true), now: Self.now)
        #expect(try #require(alice.session).confirmed)
        #expect(try #require(alice.session).peerInitEphPub == nil)
        #expect(alice.nodeId < bob.nodeId, "precondition: b is the higher node id the guard reads")

        let reset = try bob.reset(now: Self.now + 10_000)
        let followUp = try bob.seal("follow-up", now: Self.now + 10_000)
        #expect(try text(alice.open(followUp, now: Self.now + 11_000)) == "follow-up")
        #expect(try #require(alice.session).weAreInitiator, "read, not adopted")
        #expect(try #require(alice.session).peerInitEphPub == nil)

        #expect(try text(alice.open(reset, now: Self.now + 11_000, resetRequested: true)) == "reset")
        #expect(try !#require(alice.session).weAreInitiator, "the reset was adopted")
        #expect(try #require(alice.session).root == #require(bob.session).root)
    }
}
