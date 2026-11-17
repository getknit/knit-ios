import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Resets and the relay (ADR 2026-11.adrq, P4a), over ``SpoolLab``: the peer's reset reaches us through the old scope and
/// is adopted, and our own takes the pair's scopes out of our table until its answer comes by radio.
///
/// The six cases of knit-next's `ResetOverRelayLabTest` (`mesh/lab/ResetOverRelayLabTest.kt` at `0832b8462`) wait for the
/// deferred reset unit, since each has our own reset cross the relay:
/// - `aResetToAPeerOnlyTheRelayReachesCrossesItAndThePairCarriesOnUnderTheNewSession`
/// - `aSecondResetPastTheFloorWithTheFirstUnansweredStillCrossesTheRelay`
/// - `aMutualResetWhoseWinnerHearsTheAnswerFirstEndsOnTheWinnersRoot`
/// - `theReplacedErasOwnInitReplayedByTheRelayIsNoRaceAgainstOurReset`
/// - `theReplacedErasInitSealedSinceOurResetStillRacesAndThePairMeetsOnOneRoot`
/// - `aResetBobsFloorRefusedIsReOpenedWhenTheFloorEndsAndItsDmLands`
@Suite struct SpoolResetLabTests {
    @Test func aPeersResetOverTheRelayIsAdoptedAndThePairCarriesOn() throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [1])
        let old = try #require(lab.scopes(1).first)
        // Alice, offline, writes once under the old root, then resets; a test injector pushes both into the old scope as
        // Android does, the reset first.
        let oldEra = try SpoolEngineLabTests.send(lab, 0, 1, "from the old era")
        lab.advance(SpoolEngineLabTests.minute)
        let before = Set(lab[0].stores.custody.liveIds(now: lab[0].clock.wallMilliseconds()))
        guard case .sent = lab[0].engine.sendRatchetReset(to: SpoolEngineLabTests.bob.nodeId) else {
            Issue.record("alice's reset went out")
            return
        }
        lab.pump()
        #expect(lab.scopes(0).isEmpty, "alice's own reset took the pair's scopes out of her table in its turn")
        let resetId = try #require(lab[0].stores.custody.liveIds(now: lab[0].clock.wallMilliseconds()).first { !before.contains($0) })
        var injector = RawMember(lab.spool, scope: old.id)
        for id in [resetId, oldEra] {
            let carried = try #require(lab[0].stores.custody.frame(id, now: lab[0].clock.wallMilliseconds()))
            injector.push(try #require(ScopeFrames.seal(carried, into: old)))
        }
        lab.pump()
        let scopes = lab.scopes(1)
        #expect(scopes.count == 2 && scopes.last?.id == old.id && scopes.last?.retiring == true, "the old scope retires in the same turn")
        let live = try #require(scopes.first { !$0.retiring })
        #expect(live.id != old.id, "the new root's scope is live")
        lab.run(6)
        #expect(!lab.spool.liveIds(live.id).isEmpty, "bob's answer lands under the new scope")
        #expect(lab[1].stores.messages.message(oldEra) != nil, "the old era's DM opens under the drained root")
        #expect(lab[1].engine.ratchet.floors(for: SpoolEngineLabTests.alice.nodeId).undecryptableIds == 0, "no era evidence")
        #expect(lab[1].engine.dropped[.ratchetAeadFail] == nil)

        // The answer reaches Alice by radio; then text goes both ways over the relay alone.
        lab.radio.link(0, 1)
        lab.radio.unlink(0, 1)
        #expect(lab.radio.sessionsAgree(0, 1))
        lab.connect(0)
        lab.run(6)
        let toBob = try SpoolEngineLabTests.send(lab, 0, 1, "after the reset")
        let toAlice = try SpoolEngineLabTests.send(lab, 1, 0, "heard")
        lab.run(12)
        #expect(lab[1].stores.messages.message(toBob) != nil && lab[0].stores.messages.message(toAlice) != nil, "both ways")

        // The retiring scope leaves once its drain ends.
        lab.advance(48 * 60 * SpoolEngineLabTests.minute + SpoolEngineLabTests.minute)
        #expect(!lab.scopes(1).contains { $0.id == old.id }, "the drain's end took the retiring scope")
    }
    @Test func ourOwnResetTakesThePeersScopesOutUntilTheAnswer() throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [0, 1])
        let old = try #require(lab.scopes(1).first)
        let held = lab.spool.liveIds(old.id)
        lab.forgetSent(1)
        guard case .sent = lab[1].engine.sendRatchetReset(to: SpoolEngineLabTests.alice.nodeId) else {
            Issue.record("bob's reset went out")
            return
        }
        lab.pump()
        #expect(lab.scopes(1).isEmpty, "the peer's scopes left our table in the reset's turn")
        lab.run(6)
        #expect(lab.spool.liveIds(old.id) == held, "nothing reached the old scope")
        let pushes = lab.sent[1].count { if case .push = $0 { true } else { false } }
        #expect(pushes == 0, "nothing pushed under either scope")
        lab.radio.link(0, 1)
        lab.radio.unlink(0, 1)
        lab.run(2)
        #expect(lab.scopes(1).contains { !$0.retiring && $0.id != old.id }, "the answer brings the new scope")
    }
}
