import KnitWire
import Testing

@testable import KnitCrypto

/// The DM ratchet's state machine, ported case by case from knit-next's `RatchetEngineTest` (at `ac491f4c`, 43 cases),
/// each under its Kotlin name. Two sides (``RatchetSide``) hold the rows the session layer will own and apply each
/// open's delta with `RatchetRepository`'s rules, so every order the mesh forces (reordering, holes, re-serves, races,
/// wipes and resets) is a plain test. The cases are split by theme across `RatchetEngineTests+*.swift`. knit-next's own
/// transcripts of the same engine are `RatchetTranscriptTests`', and the randomized run is `RatchetSoakTests`'.
@Suite struct RatchetEngineTests {
    static let now: Int64 = 1_700_000_000_000

    // MARK: Establishment

    @Test func initFirstMessageAndReplyConfirmBothSides() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)

        let first = try alice.seal("hello", now: Self.now)
        #expect(first.header.se == 1)
        #expect(first.header.pe == 0)
        #expect(first.header.initial != nil)

        #expect(try text(bob.open(first, now: Self.now)) == "hello")
        #expect(try #require(bob.session).confirmed)
        #expect(try !#require(bob.session).weAreInitiator)

        let reply = try bob.seal("hi back", now: Self.now)
        #expect(reply.header.se == 1)
        #expect(reply.header.pe == 1)
        #expect(reply.header.initial == nil)

        #expect(try text(alice.open(reply, now: Self.now)) == "hi back")
        #expect(try #require(alice.session).confirmed)
        #expect(try alice.seal("post-confirm", now: Self.now).header.initial == nil)
    }

    /// Kotlin compares `RatchetCrypto.exportRoot` of both roots. This port leaves the spool's exports out (ADR
    /// 2026-10.5sk9), and the export root is a function of the root alone, so the roots and their tags are compared.
    @Test func bothSidesDeriveTheSamePairwiseExportRoot() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("x", now: Self.now), now: Self.now)

        let aliceRoot = try #require(alice.session).root
        let bobRoot = try #require(bob.session).root
        #expect(aliceRoot == bobRoot)
        #expect(RatchetCrypto.rootTag(aliceRoot) == RatchetCrypto.rootTag(bobRoot))
    }

    /// The invariant the session layer's era gate rests on (knit-next ADR 026): `establishedAt` is our own clock exactly
    /// when we are the initiator, and the peer's `init.at` otherwise. Every site that writes it is walked here, each
    /// with a local clock unlike the init's `at`, so a site that takes the wrong one cannot pass by coincidence.
    @Test func establishedAtIsOurOwnClockExactlyWhenWeAreTheInitiator() throws {
        let aliceEra = Self.now
        let bobLocal = Self.now + 3 * 60 * 60_000

        // 1. initiate: our own clock.
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: aliceEra)
        #expect(try #require(alice.session).weAreInitiator)
        #expect(try #require(alice.session).establishedAt == aliceEra)

        // 2. responder establish: the peer's init.at, not the clock we opened it on.
        _ = try bob.open(alice.seal("hello", now: aliceEra), now: bobLocal)
        #expect(try !#require(bob.session).weAreInitiator)
        #expect(try #require(bob.session).establishedAt == aliceEra)

        // 3. replacement adopt (the peer lost its state and initiated again): the new init.at.
        let reEra = aliceEra + 10_000
        alice.wipe()
        try alice.initiate(now: reEra)
        _ = try bob.open(alice.seal("after my wipe", now: reEra), now: bobLocal + 10_000)
        #expect(try !#require(bob.session).weAreInitiator)
        #expect(try #require(bob.session).establishedAt == reEra)

        // 4. both initiate. The smaller node id wins, so carol keeps her own stamp and dave, adopting the winner's root,
        //    takes the winner's clock with it.
        let (carol, dave) = try RatchetSide.pair()
        let carolEra = Self.now + 60_000
        let daveEra = Self.now + 90_000
        try carol.initiate(now: carolEra)
        try dave.initiate(now: daveEra)
        let fromC = try carol.seal("mine", now: carolEra)
        let fromD = try dave.seal("no, mine", now: daveEra)
        _ = try dave.open(fromC, now: daveEra)
        _ = try carol.open(fromD, now: carolEra)

        #expect(try !#require(dave.session).weAreInitiator, "the larger node id adopts the winner's root")
        #expect(try #require(dave.session).establishedAt == carolEra)
        #expect(try #require(carol.session).weAreInitiator, "the race winner stays the initiator")
        #expect(try #require(carol.session).establishedAt == carolEra)
    }
}
