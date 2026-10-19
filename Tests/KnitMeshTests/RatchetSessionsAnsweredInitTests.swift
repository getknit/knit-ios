import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// An init a session of ours anchored before, in the facade (ADR 2026-10.wcex): kept by its ephemeral across a reinstall,
/// which loses the session rows, it establishes, races and replaces nothing, counts only as `NO_SESSION` while no session
/// is held, and says whether the session held calls for our flagged reset at once. An init the session held is anchored on,
/// or whose era it still drains, keeps Kotlin's rules.
@Suite struct RatchetSessionsAnsweredInitTests {
    private static let now: Int64 = 1_756_200_000_000
    private static let minute: Int64 = 60_000

    /// Alice's opener to Bob, which Bob answers by anchoring its init, and its ephemeral.
    private struct Answered {
        let alice: RatchetSessionSide
        let bob: RatchetSessionSide
        let opener: EncEnvelope
        let eph: [UInt8]
    }

    private func answeredOpener() throws -> Answered {
        let (alice, bob) = try RatchetSessionSide.pair()
        let opener = try alice.seal("the opener", now: Self.now)
        let eph = try #require(opener.ratchet?.initial?.eph)
        #expect(plaintext(try bob.open(opener, now: Self.now)) != nil)
        #expect(bob.session?.peerInitEphPub == eph, "Bob anchored the opener's init")
        return Answered(alice: alice, bob: bob, opener: opener, eph: eph)
    }

    /// Opens `envelope` at `side` with `kept` as the ephemerals its identity's item keeps.
    private func open(
        _ envelope: EncEnvelope, at side: RatchetSessionSide, kept: [UInt8], now: Int64
    ) throws -> RatchetSessions.Answer<RatchetSessions.Opening<Void>> {
        let frame = try #require(RatchetSessions.Frame(envelope: envelope, aad: RatchetSessionSide.aad))
        return side.sessions.open(
            frame,
            from: side.peer.identity.bundle,
            now: now,
            answeredBefore: { $0 == kept },
            prekeys: { [side] in side.prekeys[$0] },
            alongside: { _ in () }
        )
    }

    private func stale(_ answer: RatchetSessions.Answer<RatchetSessions.Opening<Void>>) -> (RatchetEngine.OpenOutcome.Failed, Bool)? {
        guard case .settled(.stale(let failure, let resetsAtOnce)) = answer else {
            return nil
        }
        return (failure, resetsAtOnce)
    }

    @Test func anAnsweredInitWithNoSessionHeldEstablishesNothingAndResetsAtOnce() throws {
        let answered = try answeredOpener()
        let alice = answered.alice
        let bob = answered.bob
        let eph = answered.eph
        let opener = answered.opener
        defer { extendLifetime(alice) } // Bob links back to Alice weakly.
        bob.wipe()
        let answer = try open(opener, at: bob, kept: eph, now: Self.now + Self.minute)
        #expect(stale(answer)?.0 == .noSession && stale(answer)?.1 == true, "\(answer)")
        #expect(bob.session == nil, "nothing established")
        // Without the kept ephemeral, the same frame rebuilds the old root as a fresh responder: today's defect.
        #expect(plaintext(try bob.open(opener, now: Self.now + Self.minute)) != nil)
    }

    @Test func anAnsweredInitAgainstOurOwnUnansweredPlainInitRacesNothingAndResetsAtOnce() throws {
        let answered = try answeredOpener()
        let alice = answered.alice
        let bob = answered.bob
        let eph = answered.eph
        let opener = answered.opener
        defer { extendLifetime(alice) } // Bob links back to Alice weakly.
        bob.wipe()
        _ = try bob.seal("a tick's plain init", now: Self.now + Self.minute)
        let held = try #require(bob.session)
        #expect(held.weAreInitiator && !held.confirmed && held.lastResetSentAt < held.establishedAt)

        let answer = try open(opener, at: bob, kept: eph, now: Self.now + 2 * Self.minute)
        #expect(stale(answer)?.1 == true, "our own plain init, no reset since: the mark goes at once (\(answer))")
        #expect(bob.session?.root == held.root && bob.session?.confirmed == false, "no race, whichever id is the smaller")
    }

    @Test func anAnsweredInitAfterOurResetRacesNothingAndSendsNoSecondReset() throws {
        let answered = try answeredOpener()
        let alice = answered.alice
        let bob = answered.bob
        let eph = answered.eph
        let opener = answered.opener
        defer { extendLifetime(alice) } // Bob links back to Alice weakly.
        bob.wipe()
        _ = try sealedReset(try bob.reset(now: Self.now + Self.minute))
        let held = try #require(bob.session)

        let answer = try open(opener, at: bob, kept: eph, now: Self.now + 2 * Self.minute)
        #expect(stale(answer) != nil && stale(answer)?.1 == false, "our reset has gone: \(answer)")
        #expect(stale(answer)?.0 != .noSession, "a session is held, so it does not count as NO_SESSION")
        #expect(bob.session?.root == held.root && bob.session?.establishedAt == held.establishedAt)
    }

    @Test func anAnsweredInitAgainstAConfirmedSessionCallsForNoReset() throws {
        let answered = try answeredOpener()
        let alice = answered.alice
        let bob = answered.bob
        let eph = answered.eph
        let opener = answered.opener
        defer { extendLifetime(alice) } // Bob links back to Alice weakly.
        // Bob's answer confirms Alice, so her reset after his wipe is a fresh init, which he adopts as a fresh responder: a
        // confirmed session on another init.
        #expect(plaintext(try alice.open(try bob.seal("the answer", now: Self.now + 1), now: Self.now + 2)) != nil)
        bob.wipe()
        _ = try sealedReset(try alice.reset(now: Self.now + Self.minute))
        let resetFrame = try alice.seal("under the reset", now: Self.now + Self.minute + 1)
        #expect(plaintext(try bob.open(resetFrame, now: Self.now + Self.minute + 2)) != nil)
        let held = try #require(bob.session)
        #expect(held.confirmed && !held.weAreInitiator)

        let answer = try open(opener, at: bob, kept: eph, now: Self.now + 2 * Self.minute)
        #expect(stale(answer)?.1 == false, "\(answer)")
        #expect(bob.session?.root == held.root)
    }

    @Test func theInitTheSessionHeldIsAnchoredOnOpensAsItAlwaysDid() throws {
        let answered = try answeredOpener()
        let alice = answered.alice
        let bob = answered.bob
        let eph = answered.eph
        defer { extendLifetime(alice) } // Bob links back to Alice weakly.
        // Alice has had no answer, so her next DM still carries the init Bob anchored.
        let next = try alice.seal("still unanswered", now: Self.now + 1)
        #expect(next.ratchet?.initial?.eph == eph)
        #expect(plaintext(try open(next, at: bob, kept: eph, now: Self.now + 2)) == Array("still unanswered".utf8))
    }

    /// The carve-out for an era we still hold: Bob anchored Alice's init, then reset the pair himself before she heard his
    /// answer, so the root her init founded drains as his previous one. Her next DM, still on that root and carrying that
    /// init, races his reset as Kotlin races it, by node id, whatever the kept ephemerals say: only an era a reinstall lost
    /// reads as stale.
    @Test func anAnsweredInitWhoseEraOurSessionStillDrainsRacesAsBefore() throws {
        let answered = try answeredOpener()
        let alice = answered.alice
        let bob = answered.bob
        let eph = answered.eph
        defer { extendLifetime(alice) } // Bob links back to Alice weakly.
        let first = try #require(bob.session).root
        _ = try sealedReset(try bob.reset(now: Self.now + Self.minute))
        let reset = try #require(bob.session)
        #expect(reset.prevRoot == first)
        let next = try alice.seal("still on the first root", now: Self.now + Self.minute + 1)
        #expect(next.ratchet?.initial?.eph == eph)

        let answer = try open(next, at: bob, kept: eph, now: Self.now + Self.minute + 2)
        #expect(stale(answer) == nil && plaintext(answer) != nil, "opened as an init of an era we hold, so answered: \(answer)")
        let aliceWins = alice.nodeId < bob.nodeId
        #expect(bob.session?.root == (aliceWins ? first : reset.root), "the race by node id")
    }
}
