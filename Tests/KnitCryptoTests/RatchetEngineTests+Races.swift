import KnitWire
import Testing

@testable import KnitCrypto

/// Both sides initiate (knit-next ADR 2026-09.pz9g): the smaller node id wins on both ends, never the earlier stamp.
extension RatchetEngineTests {
    @Test func bothInitiateRaceConvergesOnTheLowerNodeIdsSession() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        try bob.initiate(now: Self.now)
        let fromA = try alice.seal("from a", now: Self.now)
        let fromB = try bob.seal("from b", now: Self.now)

        // alice, the smaller node id, wins on both ends: she keeps her root and drains bob's, and bob adopts hers.
        #expect(try text(alice.open(fromB, now: Self.now)) == "from b")
        #expect(try #require(alice.session).weAreInitiator)
        #expect(try #require(alice.session).prevRoot != nil)

        #expect(try text(bob.open(fromA, now: Self.now)) == "from a")
        #expect(try #require(bob.session).confirmed)
        #expect(try !#require(bob.session).weAreInitiator)
        #expect(try #require(alice.session).root == #require(bob.session).root)

        // Traffic flows both ways under the winning root, and bob's numbering stayed monotone.
        let bNext = try bob.seal("under the winning root", now: Self.now)
        #expect(bNext.header.se == 2)
        #expect(try text(alice.open(bNext, now: Self.now)) == "under the winning root")
        #expect(try #require(alice.session).confirmed)
        #expect(try text(bob.open(alice.seal("ack", now: Self.now), now: Self.now)) == "ack")
    }

    @Test func theRaceLoserDropsTheRecvStateOfTheEraItAbandons() throws {
        let (alice, bob) = try RatchetSide.pair()
        // Spend two indices under the era before the race, so bob holds a chain for epoch 1 that a restarted numbering
        // will collide with.
        try alice.initiate(now: Self.now)
        #expect(try text(bob.open(alice.seal("one", now: Self.now), now: Self.now)) == "one")
        #expect(try text(bob.open(alice.seal("two", now: Self.now), now: Self.now)) == "two")
        #expect(bob.recvNumbers == [1])

        // Both sides initiate at each other again: two peers resetting each other.
        try alice.initiate(now: Self.now + 1)
        try bob.initiate(now: Self.now + 1)
        let fromA = try alice.seal("after the race", now: Self.now + 1)

        // bob loses and adopts alice's root. The rows above describe chains under the era he just left; kept, alice's
        // restarted epoch 1 would land on a spent index and read as a duplicate, benign per frame and a one-way deadlock in
        // all.
        #expect(try text(bob.open(fromA, now: Self.now + 1)) == "after the race")
        #expect(try #require(bob.lastDelta).purgePeerRecvState, "adopting the winner's root must drop the loser's receive state")
        #expect(bob.recvNumbers == [fromA.header.se], "only the freshly derived epoch survives")
    }

    @Test func raceLosersInFlightFramesStillDrainViaThePreviousRoot() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        try bob.initiate(now: Self.now)
        let early0 = try bob.seal("early 0", now: Self.now)
        let early1 = try bob.seal("early 1", now: Self.now)

        #expect(try text(alice.open(early1, now: Self.now)) == "early 1")
        _ = try bob.open(alice.seal("from a", now: Self.now), now: Self.now)

        // A late copy from the loser's root still opens: its chain was derived before the race resolved, and a chain
        // never needs its root again.
        #expect(try text(alice.open(early0, now: Self.now)) == "early 0")
    }

    @Test func aReservedRaceInitNeverReplacesTheResolvedSession() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        try bob.initiate(now: Self.now + 5000)
        let fromB = try bob.seal("from b", now: Self.now + 5000)
        let fromA = try alice.seal("from a", now: Self.now)

        #expect(try text(alice.open(fromB, now: Self.now)) == "from b")
        #expect(try text(bob.open(fromA, now: Self.now)) == "from a")
        #expect(try text(alice.open(bob.seal("settle", now: Self.now), now: Self.now)) == "settle")
        #expect(try #require(alice.session).confirmed)
        let rootAfterRace = try #require(alice.session).root

        // The loser's init re-served from custody hours later. Its stamp is newer than the winning session's
        // establishedAt, so a stamp-based rule would take it for a fresh replacement on every re-serve for a whole TTL;
        // the ephemeral's anchor must find it already resolved.
        #expect(try alice.open(fromB, now: Self.now + 60_000).failure == .duplicate)
        #expect(try #require(alice.session).root == rootAfterRace)
        #expect(try #require(alice.session).confirmed)
    }

    /// The remnant guard's branch: the loser's init is newer than the session the winner confirmed.
    @Test func aRaceLosersLateOpeningDmOpensReadOnlyWhenItInitiatedLater() throws {
        try raceLosersLateOpeningDmOpensReadOnly(loserInitiatedAt: Self.now + 5000)
    }

    /// The stale-init branch: the loser's init is older than the session the winner confirmed.
    @Test func aRaceLosersLateOpeningDmOpensReadOnlyWhenItInitiatedEarlier() throws {
        try raceLosersLateOpeningDmOpensReadOnly(loserInitiatedAt: Self.now - 5000)
    }

    /// #83. The race resolves entirely through alice's frames: bob adopts her root and answers under it, and she confirms
    /// on the answer without ever reading bob's init, so nothing anchors it. Bob's opening DM, sealed under his losing
    /// root while the two were apart, lands after that. It is a real message: it must open, read-only, and never replace the
    /// session both sides share.
    private func raceLosersLateOpeningDmOpensReadOnly(loserInitiatedAt: Int64) throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        try bob.initiate(now: loserInitiatedAt)
        let opening = try bob.seal("from b, losing root", now: loserInitiatedAt)

        _ = try bob.open(alice.seal("from a", now: Self.now), now: Self.now)
        _ = try alice.open(bob.seal("reply under the winner", now: Self.now), now: Self.now)
        let settled = try #require(alice.session)
        #expect(settled.confirmed)
        #expect(settled.peerInitEphPub == nil)

        #expect(try text(alice.open(opening, now: Self.now + 60_000)) == "from b, losing root")
        let after = try #require(alice.session)
        #expect(after.root == settled.root, "never defects to the losing root")
        #expect(after.prevRoot == nil, "no prevRoot is kept for it")
        #expect(after.peerInitEphPub == nil, "no anchor is recorded")
        #expect(after.peerBaseEpoch == settled.peerBaseEpoch)
        #expect(after.highestPeAcked == settled.highestPeAcked)
        #expect(after.confirmed && after.weAreInitiator)

        // Custody re-serves it for a TTL: the chain its first open stored makes every copy benign.
        #expect(try alice.open(opening, now: Self.now + 120_000).failure == .duplicate)
        #expect(try text(bob.open(alice.seal("still talking", now: Self.now + 120_000), now: Self.now + 120_000)) == "still talking")
        #expect(try text(alice.open(bob.seal("both ways", now: Self.now + 120_000), now: Self.now + 120_000)) == "both ways")
    }

    /// The winner reads the loser's pre-adoption frames, the second on the live chain, but their epoch sits under the
    /// root it is abandoning, so it never becomes the winner's DH base: the winner stays on the loser's prekey, init
    /// attached, until the loser answers under the winning root.
    @Test func theRaceWinnerNeverTakesTheLosersPreAdoptionEpochAsItsDhBase() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        try bob.initiate(now: Self.now)
        let early0 = try bob.seal("early 0", now: Self.now)
        let early1 = try bob.seal("early 1", now: Self.now)

        #expect(try text(alice.open(early0, now: Self.now)) == "early 0")
        #expect(try text(alice.open(early1, now: Self.now)) == "early 1")
        #expect(try #require(alice.session).peerBaseEpoch == 0)
        let fromA = try alice.seal("from a", now: Self.now)
        #expect(fromA.header.pe == 0)
        #expect(fromA.header.initial != nil)

        #expect(try text(bob.open(fromA, now: Self.now)) == "from a")
        #expect(try text(alice.open(bob.seal("answer", now: Self.now), now: Self.now)) == "answer")
        #expect(try #require(alice.session).confirmed)
        #expect(try #require(alice.session).root == #require(bob.session).root)
    }
}
