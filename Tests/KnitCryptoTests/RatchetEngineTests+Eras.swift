import KnitWire
import Testing

@testable import KnitCrypto

/// Receive state keyed by the root that derived it (#135, knit-next ADR 2026-10.gcrd), and a reset's kept `prevRoot`,
/// whose frames move no era (#87, knit-next ADR 2026-09.pz9g).
extension RatchetEngineTests {
    // MARK: #135

    /// bob read alice's epochs 1 and 2 under the first root, then adopted her reset: numbering restarted, the root kept as
    /// prevRoot. `turnaround` is her old-era epoch 2, n 0, read before the reset; `late` its n 1, still on its way.
    private struct AfterReset {
        let alice: RatchetSide
        let bob: RatchetSide
        /// Alice's old-era epoch 2, n 0, read by bob before the reset.
        let turnaround: RatchetFrame
        /// Its n 1, still on its way when the reset lands.
        let late: RatchetFrame
    }

    private func resetAfterEpochTwo() throws -> AfterReset {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("hello", now: Self.now), now: Self.now)
        _ = try alice.open(bob.seal("hi", now: Self.now), now: Self.now)
        let turnaround = try alice.seal("turnaround", now: Self.now)
        let late = try alice.seal("late", now: Self.now)
        #expect(turnaround.header.se == 2)
        #expect(late.header.se == 2)
        #expect(try text(bob.open(turnaround, now: Self.now)) == "turnaround")
        #expect(try text(bob.open(alice.reset(now: Self.now + 1000), now: Self.now + 2000, resetRequested: true)) == "reset")
        #expect(try #require(bob.session).prevRoot != nil)
        return AfterReset(alice: alice, bob: bob, turnaround: turnaround, late: late)
    }

    /// bob answers the reset, which moves alice's restarted numbering to epoch 2; answers that epoch's n 0, unopened.
    private func newEraEpochTwo(_ alice: RatchetSide, _ bob: RatchetSide, now: Int64) throws -> RatchetFrame {
        #expect(try text(alice.open(bob.seal("answer", now: now), now: now)) == "answer")
        let frame = try alice.seal("new era, epoch 2", now: now)
        #expect(frame.header.se == 2)
        return frame
    }

    /// Custody re-served alice's old epoch-2 frame after the reset's purge (a receipt has no message row to stop it), so
    /// it opened again under prevRoot and stored a chain at number 2 with its index spent. Her new epoch 2 must open
    /// fresh under the active root, not read DUPLICATE off the old era's cursor.
    @Test func aChainReDrainedUnderPrevRootNeverDecidesTheNewEraFrameOfItsNumber() throws {
        let reset = try resetAfterEpochTwo()
        let bob = reset.bob
        #expect(try text(bob.open(reset.turnaround, now: Self.now + 3000)) == "turnaround")
        let newTwo = try newEraEpochTwo(reset.alice, bob, now: Self.now + 4000)

        #expect(try text(bob.open(newTwo, now: Self.now + 4000)) == "new era, epoch 2")
        let session = try #require(bob.session)
        #expect(session.peerBaseEpoch == 2, "a fresh epoch under the active root moved the era")
        let tags = Set(bob.rows.chains.keys.filter { $0.epoch == 2 }.map(\.rootTag))
        let roots = try [RatchetCrypto.rootTag(session.root), RatchetCrypto.rootTag(#require(session.prevRoot))]
        #expect(tags == Set(roots), "both eras keep a chain for number 2, one per root")
        // A genuine re-serve of either is still a duplicate, never an AEAD_FAIL from the other root's attempt.
        #expect(try bob.open(newTwo, now: Self.now + 5000).failure == .duplicate)
        #expect(try bob.open(reset.turnaround, now: Self.now + 5000).failure == .duplicate)
    }

    /// The drained old-era frame sat mid-epoch, so opening it banked a skipped key for the index below under the old
    /// root. Alice's new epoch 2, n 0, must not meet that key; the old era's own n 0 still opens on it.
    @Test func aSkippedKeyBankedUnderPrevRootNeverDecidesTheNewEraFrameAtItsIndex() throws {
        let reset = try resetAfterEpochTwo()
        let bob = reset.bob
        #expect(try text(bob.open(reset.late, now: Self.now + 3000)) == "late") // banks (2, 0) under the old root
        let newTwo = try newEraEpochTwo(reset.alice, bob, now: Self.now + 4000)

        #expect(try text(bob.open(newTwo, now: Self.now + 4000)) == "new era, epoch 2")
        #expect(try text(bob.open(reset.turnaround, now: Self.now + 5000)) == "turnaround", "the old era's key is untouched")
    }

    /// The other order: the new era owns number 2 before the old era's late frame lands. That frame drains under
    /// prevRoot on a fresh derivation, no longer failing against the new chain, and moves nothing.
    @Test func anOldEraFrameOnANumberTheNewEraOwnsStillDrainsUnderPrevRoot() throws {
        let reset = try resetAfterEpochTwo()
        let bob = reset.bob
        #expect(try text(bob.open(newEraEpochTwo(reset.alice, bob, now: Self.now + 3000), now: Self.now + 3000)) == "new era, epoch 2")
        let before = try #require(bob.session)

        #expect(try text(bob.open(reset.late, now: Self.now + 4000)) == "late")
        let after = try #require(bob.session)
        #expect(after.root == before.root)
        #expect(after.peerBaseEpoch == before.peerBaseEpoch)
        #expect(after.peerBasePub == before.peerBasePub)
    }

    // MARK: #87

    /// A session that has turned around once: alice is at epoch 2, and bob's next frames seal against it.
    private func turnedAround() throws -> (RatchetSide, RatchetSide) {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("hello", now: Self.now), now: Self.now)
        _ = try alice.open(bob.seal("hi", now: Self.now), now: Self.now)
        _ = try bob.open(alice.seal("turnaround", now: Self.now), now: Self.now)
        return (alice, bob)
    }

    /// alice resets while bob is away; his DMs sealed meanwhile name her dead-era epoch 2, whose key survives the reset
    /// (it minted only epoch 1). In whatever order they land they open under the kept prevRoot and must leave the
    /// replacement exactly as the reset minted it: unconfirmed, init still riding, no DH base from the dead era, no pe
    /// ack. Then what #87 lost: alice's answer carries the init, so bob, who has not seen the reset, adopts from the
    /// answer itself, and the reset landing last opens on the skipped key.
    private func oldEraFramesNeverConfirmAResetsReplacement(_ order: (RatchetFrame, RatchetFrame) -> [RatchetFrame]) throws {
        let (alice, bob) = try turnedAround()
        let apart0 = try bob.seal("apart 0", now: Self.now + 1000)
        let apart1 = try bob.seal("apart 1", now: Self.now + 1000)
        #expect(apart0.header.pe == 2)
        let reset = try alice.reset(now: Self.now + 2000)

        for frame in order(apart0, apart1) {
            #expect(try alice.open(frame, now: Self.now + 3000).opened != nil)
        }
        let replacement = try #require(alice.session)
        #expect(!replacement.confirmed, "a frame from the dead era confirmed the replacement")
        #expect(replacement.initEphPub != nil)
        #expect(replacement.peerBaseEpoch == 0)
        #expect(replacement.highestPeAcked == 0)

        let tick = try alice.seal("tick", now: Self.now + 3000)
        #expect(tick.header.initial != nil, "the answer still carries the reset's init")
        #expect(tick.header.pe == 0)
        #expect(try text(bob.open(tick, now: Self.now + 4000)) == "tick")
        #expect(try #require(bob.session).root == replacement.root, "b adopted the reset from the answer")
        #expect(try text(bob.open(reset, now: Self.now + 4000, resetRequested: true)) == "reset")

        #expect(try text(alice.open(bob.seal("after", now: Self.now + 5000), now: Self.now + 5000)) == "after")
        #expect(try #require(alice.session).confirmed)
    }

    @Test func aFrameOpenedUnderAResetsKeptPrevRootNeverConfirmsTheReplacement() throws {
        try oldEraFramesNeverConfirmAResetsReplacement { apart0, _ in [apart0] }
    }

    /// The second frame of the dead-era epoch opens on the live chain its first one derived.
    @Test func aSecondOldEraFrameOnTheLiveChainNeverConfirmsTheReplacement() throws {
        try oldEraFramesNeverConfirmAResetsReplacement { apart0, apart1 in [apart0, apart1] }
    }

    /// Out of order: the first frame of the dead-era epoch opens on the skipped key the second one stored.
    @Test func anOldEraPairOpenedOutOfOrderNeverConfirmsTheReplacementThroughItsSkippedKey() throws {
        try oldEraFramesNeverConfirmAResetsReplacement { apart0, apart1 in [apart1, apart0] }
    }

    /// The adopter's side of the same rule. bob adopts alice's reset, and her dead-era epoch 2, numbered above the
    /// reset's epoch 1, then drains in under prevRoot, twice. Taken as bob's DH base, his next frames would seal against
    /// a key she replaces the moment her own numbering reaches 2, and the damped adoption would refuse her fresh epochs
    /// until they climbed past it.
    @Test func oldEraFramesDrainingAfterAnAdoptedResetNeverBecomeTheAdoptersDhBase() throws {
        let (alice, bob) = try turnedAround()
        let old0 = try alice.seal("old 0", now: Self.now + 1000)
        let old1 = try alice.seal("old 1", now: Self.now + 1000)
        #expect(old0.header.se == 2)
        let reset = try alice.reset(now: Self.now + 2000)

        #expect(try text(bob.open(reset, now: Self.now + 3000, resetRequested: true)) == "reset")
        #expect(try text(bob.open(old0, now: Self.now + 3000)) == "old 0")
        #expect(try text(bob.open(old1, now: Self.now + 3000)) == "old 1")
        #expect(try #require(bob.session).peerBaseEpoch == 1)
        #expect(try #require(bob.session).peerBasePub == reset.header.ek)

        let back = try bob.seal("back", now: Self.now + 4000)
        #expect(back.header.pe == 1)
        #expect(try text(alice.open(back, now: Self.now + 4000)) == "back")
        #expect(try #require(alice.session).confirmed)
    }

    /// The era is the root a frame opened under, not the number of our epoch it names. A peer that took one of our
    /// dead-era epochs as its base before this rule (an older build) seals under the new root against it; that frame is
    /// this era's, and must still confirm the replacement.
    @Test func anInEraFrameNamingOurRetiredEpochStillConfirmsTheReplacement() throws {
        let (alice, bob) = try turnedAround()
        let deadEraEpoch2 = try #require(alice.rows.localEpochs[2])
        let reset = try alice.reset(now: Self.now + 1000)
        _ = try bob.open(reset, now: Self.now + 2000, resetRequested: true)
        bob.session?.peerBasePub = deadEraEpoch2.publicKey
        bob.session?.peerBaseEpoch = 2

        let inEra = try bob.seal("in era", now: Self.now + 2000)
        #expect(inEra.header.pe == 2)
        #expect(try text(alice.open(inEra, now: Self.now + 2000)) == "in era")
        #expect(try #require(alice.session).confirmed)
    }
}
