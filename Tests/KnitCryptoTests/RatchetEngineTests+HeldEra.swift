import KnitWire
import Testing

@testable import KnitCrypto

/// An open that may not move the era (``RatchetEngine/OpenContext/allowEraChange``), this port's own: the start's replay
/// out of our own custody (ADR 2026-10.5sk9, phase P5a). An init the held session has not resolved neither races nor
/// replaces it, flagged or not, and the frame is read under the roots held; with no session held, an init still
/// establishes one, and an init the session resolved still reads.
extension RatchetEngineTests {
    @Test func anOpenThatMayNotMoveTheEraLeavesARaceUnresolvedOnBothEnds() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        try bob.initiate(now: Self.now)
        let fromA = try alice.seal("from a", now: Self.now)
        let fromB = try bob.seal("from b", now: Self.now)
        let alices = try #require(alice.session)
        let bobs = try #require(bob.session)

        // alice would win, and bob would lose and adopt her root: held, neither moves.
        #expect(try alice.open(fromB, now: Self.now, allowEraChange: false).failure == .aeadFail)
        #expect(alice.session == alices)
        #expect(try bob.open(fromA, now: Self.now, allowEraChange: false).failure == .aeadFail)
        #expect(bob.session == bobs)

        // The same frames, as their first verdicts, race as they always have.
        #expect(try text(alice.open(fromB, now: Self.now)) == "from b")
        #expect(try text(bob.open(fromA, now: Self.now)) == "from a")
        #expect(try #require(alice.session).root == #require(bob.session).root)
    }

    @Test func anOpenThatMayNotMoveTheEraRefusesAReplacementFlaggedOrNot() throws {
        let (alice, bob) = try RatchetSide.pair()
        try bob.initiate(now: Self.now)
        #expect(try text(alice.open(bob.seal("hello", now: Self.now), now: Self.now)) == "hello")
        let held = try #require(alice.session)
        #expect(held.confirmed && !held.weAreInitiator, "a responder, so no remnant guard stands in for the rule")

        // bob loses his state and starts over: a fresh init, newer than the session, then a flagged reset.
        bob.wipe()
        try bob.initiate(now: Self.now + 10_000)
        let reborn = try bob.seal("reborn", now: Self.now + 10_000)
        #expect(try alice.open(reborn, now: Self.now + 10_000, allowEraChange: false).failure != nil)
        #expect(alice.session == held)
        let reset = try bob.reset(now: Self.now + 20_000)
        #expect(try alice.open(reset, now: Self.now + 20_000, resetRequested: true, allowEraChange: false).failure != nil)
        #expect(alice.session == held)

        // As its first verdict the reset replaces the session.
        #expect(try text(alice.open(reset, now: Self.now + 20_000, resetRequested: true)) == "reset")
        #expect(try #require(alice.session).root != held.root)
    }

    @Test func anOpenThatMayNotMoveTheEraStillEstablishesAFirstSessionAndReadsTheInitItResolved() throws {
        let (alice, bob) = try RatchetSide.pair()
        try bob.initiate(now: Self.now)
        #expect(try text(alice.open(bob.seal("first", now: Self.now), now: Self.now, allowEraChange: false)) == "first")
        let established = try #require(alice.session)
        #expect(established.confirmed && !established.weAreInitiator)
        // bob is unconfirmed, so his next frame carries the same init, which the session resolved: it reads.
        #expect(try text(alice.open(bob.seal("second", now: Self.now), now: Self.now, allowEraChange: false)) == "second")
        #expect(try #require(alice.session).root == established.root)
    }
}
