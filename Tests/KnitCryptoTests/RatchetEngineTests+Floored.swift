import KnitWire
import Testing

@testable import KnitCrypto

/// A reset the replacement floor refuses (knit-next ADR 2026-11.sfms, #251; ADR 2026-10.5sk9's P9b amendment), after
/// knit-next's `RatchetEngineTest` #251 cases at `f018bc8ce` (`RatchetEngineTest.kt:726-809`): a flagged init the floor
/// alone refused, for a root never held, is `RESET_FLOORED` and never `DUPLICATE`; the unflagged and adopted re-serves keep
/// their verdicts; a re-entry of a reset we adopted and left is never floored; and this port's own cases, the start's
/// replay, an init answered before a reinstall and an ephemeral X25519 refuses.
extension RatchetEngineTests {
    /// A confirmed pair where `resetter` reset once and the other side adopted it, starting its one-minute floor
    /// (`adoptedOneReset`, `RatchetEngineTest.kt:728-735`).
    private func adoptedOneReset() throws -> (adopter: RatchetSide, resetter: RatchetSide) {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("hello", now: Self.now), now: Self.now)
        _ = try alice.open(bob.seal("hi", now: Self.now), now: Self.now)
        #expect(try text(alice.open(bob.reset(now: Self.now + 10_000), now: Self.now + 10_000, resetRequested: true)) == "reset")
        return (alice, bob)
    }

    /// `aResetTheFloorRefusesForAnEraWeNeverHeldIsFlooredNeverDuplicate` (`:743-756`): the resetter resets again a few
    /// seconds after the first was adopted, its numbering restarted, so the second reset's `se = 1 n = 0` meets the row the
    /// first reset's own `se = 1 n = 0` left. Exactly `RESET_FLOORED`: a test that asserted only "not `DUPLICATE`" would pass
    /// on `AEAD_FAIL` too. Once the floor ends the same frame is adopted.
    @Test func aResetTheFloorRefusesForAnEraWeNeverHeldIsFlooredNeverDuplicate() throws {
        let (alice, bob) = try adoptedOneReset()
        let root = try #require(alice.session).root
        let second = try bob.reset(now: Self.now + 13_000)
        #expect(second.header.se == 1 && second.header.n == 0, "the restarted numbering meets the first reset's row")
        let floored = try alice.open(second, now: Self.now + 13_000, resetRequested: true, allowReplacement: false)
        #expect(floored.failure == .resetFloored)
        #expect(try #require(alice.session).root == root, "refused: nothing moved")

        #expect(try text(alice.open(second, now: Self.now + 71_000, resetRequested: true)) == "reset")
        #expect(try #require(alice.session).root == #require(bob.session).root)
    }

    /// `anUnflaggedInitTheFloorRefusesKeepsItsVerdict` (`:758-764`): only a reset is held.
    @Test func anUnflaggedInitTheFloorRefusesKeepsItsVerdict() throws {
        let (alice, bob) = try adoptedOneReset()
        #expect(try alice.open(bob.reset(now: Self.now + 13_000), now: Self.now + 13_000, allowReplacement: false).failure == .duplicate)
    }

    /// `anAdoptedResetsReServeInsideTheFloorStaysDuplicate` (`:766-779`): anchored by its ephemeral, inside the floor too.
    @Test func anAdoptedResetsReServeInsideTheFloorStaysDuplicate() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("hello", now: Self.now), now: Self.now)
        _ = try alice.open(bob.seal("hi", now: Self.now), now: Self.now)
        let reset = try bob.reset(now: Self.now + 10_000)
        _ = try alice.open(reset, now: Self.now + 10_000, resetRequested: true)
        #expect(try alice.open(reset, now: Self.now + 20_000, resetRequested: true, allowReplacement: false).failure == .duplicate)
    }

    /// `aReEntryOfAResetWeAdoptedAndLeftIsNeverFloored` (`:781-809`), the design pass's blocking case on Android: Bob adopts
    /// Alice's reset, then re-roots inside the minute and Alice answers, so Bob's own initiation dropped the anchor on her
    /// reset and keeps its root as `prevRoot`. A re-entry of her reset, her clock ahead so its `at` is past his re-root,
    /// inside the floor, is an era he held and left: read under the kept `prevRoot` first, and then a duplicate, never
    /// floored, or its re-open would adopt a root she has left.
    @Test func aReEntryOfAResetWeAdoptedAndLeftIsNeverFloored() throws {
        let (bob, alice) = try RatchetSide.pair()
        try bob.initiate(now: Self.now)
        _ = try alice.open(bob.seal("hello", now: Self.now), now: Self.now)
        _ = try bob.open(alice.seal("hi", now: Self.now), now: Self.now)
        let aliceReset = try alice.reset(now: Self.now + 50_000) // her clock 40 s ahead of his
        #expect(try text(bob.open(aliceReset, now: Self.now + 10_000, resetRequested: true)) == "reset")

        #expect(try text(alice.open(bob.reset(now: Self.now + 20_000), now: Self.now + 20_000, resetRequested: true)) == "reset")
        #expect(try text(bob.open(alice.seal("answered", now: Self.now + 21_000), now: Self.now + 21_000)) == "answered")
        let bobs = try #require(bob.session)
        #expect(bobs.confirmed && bobs.weAreInitiator)
        #expect(bobs.peerInitEphPub == nil, "bob's re-root dropped the anchor")
        #expect(Self.now + 50_000 > bobs.establishedAt, "precondition: her at is past his era")

        let reEntry = try bob.open(aliceReset, now: Self.now + 30_000, resetRequested: true, allowReplacement: false)
        #expect(try text(reEntry) == "reset", "read under the kept prevRoot")
        let again = try bob.open(aliceReset, now: Self.now + 31_000, resetRequested: true, allowReplacement: false)
        #expect(again.failure == .duplicate, "the init derives that prevRoot, so a duplicate it stays")
        #expect(try #require(bob.session).root == bobs.root, "still on his own root")
        #expect(try #require(bob.session).root == #require(alice.session).root)
    }

    /// A `prevRoot` past its drain and not yet retired is still held: the verdict reads the session's slot whatever its
    /// expiry says, as Kotlin's `listOfNotNull(resolved.session.root, resolved.session.prevRoot)` does (`:598-603`).
    @Test func aPrevRootPastItsDrainIsStillHeld() throws {
        let (bob, alice) = try RatchetSide.pair()
        try bob.initiate(now: Self.now)
        _ = try alice.open(bob.seal("hello", now: Self.now), now: Self.now)
        _ = try bob.open(alice.seal("hi", now: Self.now), now: Self.now)
        let aliceReset = try alice.reset(now: Self.now + 50_000)
        _ = try bob.open(aliceReset, now: Self.now + 10_000, resetRequested: true)
        _ = try alice.open(bob.reset(now: Self.now + 20_000), now: Self.now + 20_000, resetRequested: true)
        _ = try bob.open(alice.seal("answered", now: Self.now + 21_000), now: Self.now + 21_000)
        _ = try bob.open(aliceReset, now: Self.now + 30_000, resetRequested: true, allowReplacement: false)
        bob.session?.prevRootExpiresAt = Self.now + 29_000
        let late = try bob.open(aliceReset, now: Self.now + 31_000, resetRequested: true, allowReplacement: false)
        #expect(late.failure != .resetFloored, "an era held and left, its drain over")
    }

    /// A stale flagged init, no newer than the session we share, keeps its verdict inside the floor: it is never floored,
    /// and nor is a fresh one whose init a session of ours anchored before a reinstall (ADR 2026-10.wcex), which the guard
    /// before the marker reads under the roots held.
    @Test func aStaleOrAnsweredBeforeFlaggedInitIsNeverFloored() throws {
        let (alice, bob) = try adoptedOneReset()
        let second = try bob.reset(now: Self.now + 13_000)
        let stale = try alice.open(second, now: Self.now + 13_000, resetRequested: true, allowReplacement: false, initAnsweredBefore: true)
        #expect(stale.failure == .duplicate, "answered before a reinstall: read under the roots held")

        let older = try bob.reset(now: Self.now + 5000)
        let refused = try alice.open(older, now: Self.now + 14_000, resetRequested: true, allowReplacement: false)
        #expect(refused.failure == .duplicate, "no newer than the session it would replace: stale, whatever the floor")
    }

    /// An ephemeral X25519 refuses, on a floored flagged init, throws out of the open at the verdict's derivation, the first
    /// X3DH on it on that path: the caller refuses it with nothing counted, never as `AEAD_FAIL` or `DUPLICATE`.
    @Test func aLowOrderEphemeralOnAFlooredInitThrows() throws {
        let (alice, bob) = try adoptedOneReset()
        var second = try bob.reset(now: Self.now + 13_000)
        var header = second.header
        header.initial?.eph = [UInt8](repeating: 0, count: 32)
        second = RatchetFrame(header: header, nonce: second.nonce, ct: second.ct)
        #expect(throws: RatchetCryptoError.self) {
            try alice.open(second, now: Self.now + 13_000, resetRequested: true, allowReplacement: false)
        }
    }

    /// This port's start replay out of its own custody (``RatchetEngine/OpenContext/allowEraChange`` `false`): the floored
    /// predicate is judged whatever the floor that died with the process said, and the open moves no era. Not in the race
    /// branch's state, and not for an init answered before.
    @Test func theStartsReplayFloorsAFlaggedInitWhateverTheFloorSays() throws {
        let (alice, bob) = try adoptedOneReset()
        let held = try #require(alice.session)
        let second = try bob.reset(now: Self.now + 13_000)
        let replayed = try alice.open(second, now: Self.now + 3_600_000, resetRequested: true, allowEraChange: false)
        #expect(replayed.failure == .resetFloored)
        #expect(alice.session == held, "the era held")
        let answered = try alice.open(
            second, now: Self.now + 3_600_000, resetRequested: true, allowEraChange: false, initAnsweredBefore: true)
        #expect(answered.failure == .duplicate)
        #expect(try alice.open(second, now: Self.now + 3_600_000, allowEraChange: false).failure == .duplicate, "unflagged")

        let (carol, dave) = try RatchetSide.pair()
        try carol.initiate(now: Self.now)
        let reset = try dave.reset(now: Self.now + 10_000)
        let racing = try carol.open(reset, now: Self.now + 10_000, resetRequested: true, allowEraChange: false)
        #expect(racing.failure != .resetFloored, "our own init pending: the race branch's state")
    }
}
