import KnitWire
import Testing

@testable import KnitMesh

/// IntroSync's answer half, pure (``RatchetAnswers``; ADR 2026-10.5sk9, phase P5e): knit-next's `IntroSyncTest` answer
/// cases by name (`IntroSyncTest.kt`, at `cbf2a487`), with the engine's part, whether the answer can be sealed, played as
/// the engine plays it: a due answer it cannot seal yet stays owed, and one it seals is recorded as answered.
///
/// Accounted for and not ported:
/// - `a profile that pins while the open checks sealability still answers the init, once` and `an open that loses the
///   debt to a concurrent pin leaves the answer to the pin` (`:200-239`): the engine is one actor, so no pin lands between a
///   check and its use, and Kotlin's claim (`owed.remove(peerId, debt)`) has no race to settle;
/// - the intro send half, which waits for Contacts: `an intro waits for the prekey, then goes out exactly once`, `a
///   pinned peer is introduced at import time`, `an unconfirmed intro is re-sent only once the floor has elapsed`, `a
///   refused seal records no floor, so the next cue tries again` (its answer-half twin is
///   ``aSealThatCannotBeMadeRecordsNoFloorSoTheNextFrameTriesAgain()``), `confirmation moves the peer into grace and the pair
///   scope outlives it by the grace window`, `both sides importing each other converges with no extra sends`, `an
///   already-confirmed peer needs no intro`, `pending intros are capped, oldest first`, `wantIfRoom fills the free slots and
///   never evicts what was asked for`, `the store is the source of truth across a restart`, `the pair set reports each
///   move to the scope table and nothing else`, `before prime the pair set is unknown, so nothing reports`, the four
///   `cancel` cases, `a withdrawn peer can be wanted again and is introduced at once`, `a peer whose profile lacks the
///   ratchet is never registered`, `a pending intro is withdrawn when the peer's profile arrives without the ratchet` (its
///   answer half is ``aDebtIsForgivenWhenTheProfileThatPinsLacksTheRatchet()``), and `an intro an older build registered
///   to a ratchetless peer is withdrawn on the heal`.
///
/// `MeshEngineInitAnswerTests` runs the same rules through an engine and Android's session layer.
@Suite struct RatchetAnswersTests {
    private let bob = TestPeer(seed: 2).nodeId
    private let carol = TestPeer(seed: 3).nodeId
    private let init1 = RatchetAnswers.Init(eph: [UInt8](repeating: 1, count: 32), resetFlagged: false)
    private let init2 = RatchetAnswers.Init(eph: [UInt8](repeating: 2, count: 32), resetFlagged: false)
    private let floor = RatchetAnswers.floorMilliseconds
    private let now: Int64 = 1_000_000

    /// `an init-bearing frame is answered once per floor, and only when sealable` (`IntroSyncTest.kt:153-173`).
    @Test func anInitBearingFrameIsAnsweredOncePerFloorAndOnlyWhenSealable() {
        var answers = RatchetAnswers()
        let unsealable = answers.opened(init1, from: carol, at: now, sealable: false)
        #expect(!unsealable, "no prekey yet: nothing to answer with")
        let sealable = answers.opened(init1, from: carol, at: now, sealable: true)
        #expect(sealable)
        let copy = RatchetAnswers.Init(eph: init1.eph.map(\.self), resetFlagged: false)
        let repeated = answers.opened(copy, from: carol, at: now, sealable: true)
        #expect(!repeated, "the same init, by its bytes, inside the floor")
        let later = answers.opened(init1, from: carol, at: now + floor, sealable: true)
        #expect(later, "and again once the floor has passed")
    }

    /// The init is read from the header, its flag with it; a header with none is a confirmed peer's, never answered
    /// (`IntroSyncTest.kt:169-172`, `IntroSync.kt:227`).
    @Test func theInitIsReadFromTheHeaderAndAHeaderWithNoneIsNeverAnswered() throws {
        let ek = [UInt8](repeating: 9, count: 32)
        let initial = RatchetInit(eph: init1.eph, pkid: 1, at: now)
        #expect(RatchetAnswers.Init(RatchetHeader(se: 1, ek: ek, pe: 0, n: 0, initial: initial)) == init1)
        let flagged = try #require(RatchetAnswers.Init(RatchetHeader(se: 1, ek: ek, pe: 0, n: 0, initial: initial, flags: 1)))
        #expect(flagged.resetFlagged && flagged.eph == init1.eph)
        #expect(RatchetAnswers.Init(RatchetHeader(se: 2, ek: ek, pe: 1, n: 0)) == nil)
    }

    /// `an init that opens before its sender's profile pins is answered when the profile pins` (`IntroSyncTest.kt:176-197`,
    /// knit-next `937cf785`): the debt is taken once, and a re-flooded profile and a re-serve of the init stay floored.
    @Test func anInitThatOpensBeforeItsSendersProfilePinsIsAnsweredWhenTheProfilePins() throws {
        var answers = RatchetAnswers()
        let unsealable = answers.opened(init1, from: bob, at: now, sealable: false)
        #expect(!unsealable)
        let owed = answers.takeDebt(of: bob)
        let debt = try #require(owed, "owed, not dropped")
        #expect(debt == init1)
        let pinned = answers.opened(debt, from: bob, at: now + 1, sealable: true)
        #expect(pinned, "the profile pinned: answered")
        let again = answers.takeDebt(of: bob)
        #expect(again == nil, "owed once: a re-flooded profile finds nothing")
        let reServed = answers.opened(init1, from: bob, at: now + 2, sealable: true)
        #expect(!reServed, "and a re-serve of the init stays floored")
    }

    /// `a new init is answered inside the floor, once` (`IntroSyncTest.kt:242-256`, knit-next #87): a reset is a new init,
    /// and only our answer under it can confirm the resetter, however recently we answered the old one.
    @Test func aNewInitIsAnsweredInsideTheFloorOnce() {
        var answers = RatchetAnswers()
        let sent = [
            answers.opened(init1, from: carol, at: now, sealable: true),
            answers.opened(init2, from: carol, at: now + 1, sealable: true),
            answers.opened(init2, from: carol, at: now + 2, sealable: true),
            answers.opened(init2, from: carol, at: now + 3, sealable: true),
        ]
        #expect(sent == [true, true, false, false], "the new init answered once, its own repeats floored")
    }

    /// `an init marked as a reset is answered once more inside the floor` (`IntroSyncTest.kt:259-273`): the marked frame is
    /// the one we adopt, so it earns its own answer; its repeats, and the plain ones after it, stay floored.
    @Test func anInitMarkedAsAResetIsAnsweredOnceMoreInsideTheFloor() {
        var answers = RatchetAnswers()
        let marked = RatchetAnswers.Init(eph: init1.eph, resetFlagged: true)
        let sent = [
            answers.opened(init1, from: carol, at: now, sealable: true),
            answers.opened(marked, from: carol, at: now + 1, sealable: true),
            answers.opened(marked, from: carol, at: now + 2, sealable: true),
            answers.opened(init1, from: carol, at: now + 3, sealable: true),
        ]
        #expect(sent == [true, true, false, false], "one more for the mark, and a marked answer covers the plain init")
    }

    /// The answer half of `a refused seal records no floor, so the next cue tries again` (`IntroSyncTest.kt:117-127`): a
    /// seal the facade could not make, toward a peer who could read one, removes the debt and the floor together, as
    /// Kotlin's failed send does (`lastAnswered.remove`, `IntroSync.kt:239`), so the next frame carrying the init tries again.
    @Test func aSealThatCannotBeMadeRecordsNoFloorSoTheNextFrameTriesAgain() {
        var answers = RatchetAnswers()
        let first = answers.opened(init1, from: carol, at: now, sealable: true)
        let due = answers.owe(init2, to: carol, now: now + 1)
        #expect(first && due, "a new init, due")
        answers.unanswered(carol)
        let debt = answers.takeDebt(of: carol)
        #expect(debt == nil, "the debt went with the failed send")
        let floorless = answers.owe(init1, to: carol, now: now + 2)
        #expect(floorless, "and so did the floor, the old init's included, as in Kotlin")
    }

    /// The answer half of `a pending intro is withdrawn when the peer's profile arrives without the ratchet`
    /// (`IntroSyncTest.kt:481-493`; `onProfilePinned`, `IntroSync.kt:186-188`): the debt is forgiven, and only the next frame
    /// carrying the init owes again.
    @Test func aDebtIsForgivenWhenTheProfileThatPinsLacksTheRatchet() {
        var answers = RatchetAnswers()
        let unsealable = answers.opened(init1, from: bob, at: now, sealable: false)
        #expect(!unsealable)
        answers.forgive(bob)
        let debt = answers.takeDebt(of: bob)
        #expect(debt == nil)
        let again = answers.owe(init1, to: bob, now: now + 1)
        #expect(again, "nothing was answered, so the next frame owes again")
    }

    /// One debt per peer, the newest init's, and each peer's floor its own.
    @Test func eachPeerHoldsOneDebtAndAFloorOfItsOwn() {
        var answers = RatchetAnswers()
        let owedFirst = answers.owe(init1, to: bob, now: now)
        let owedSecond = answers.owe(init2, to: bob, now: now)
        let debt = answers.takeDebt(of: bob)
        #expect(owedFirst && owedSecond && debt == init2, "the newest init's")
        let toCarol = answers.opened(init1, from: carol, at: now, sealable: true)
        let toBob = answers.opened(init1, from: bob, at: now, sealable: true)
        #expect(toCarol && toBob, "Carol's floor holds nothing back for Bob")
    }
}

extension RatchetAnswers {
    /// One frame carrying `initial` from `peer` at `at`, answered when `sealable`, as the engine plays it: a due answer it
    /// cannot seal yet stays owed, and one it seals is recorded as answered. Answers whether it sent.
    mutating func opened(_ initial: Init, from peer: NodeId, at: Int64, sealable: Bool) -> Bool {
        guard owe(initial, to: peer, now: at), sealable else {
            return false
        }
        answered(initial, of: peer, at: at)
        return true
    }
}
