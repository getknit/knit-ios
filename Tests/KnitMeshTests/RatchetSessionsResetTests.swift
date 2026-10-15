import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// `RatchetSessions.sealResetDm` never seals a reset the peer would refuse (knit-next ADR 2026-09.qerd, #85 and #86),
/// knit-next's `RatchetSessionsResetTest` case by case (`app/src/test/.../mesh/crypto/ratchet/RatchetSessionsResetTest.kt`,
/// at `ac491f4c`), each under its Kotlin name. Two real facades over memory stores, one per side, so every case is the
/// pair's view: what we sealed and whether the peer opens it. The peer adopts a `FLAG_RESET` init only a minute after the
/// last replacement it adopted from us; a refused one is dropped as a duplicate after we have already purged the root the
/// peer is on, which is the six-hour blackout both issues end in. `t0` sits well past an hour so the peer's first
/// replacement is never floored by the clock's origin.
@Suite struct RatchetSessionsResetTests {
    static let t0: Int64 = 100_000_000
    static let t1 = t0 + 600_000
    static let floor = RatchetResetPolicy.resetReplacementMilliseconds
    static let resetBody = RatchetSessionSide.resetBody

    /// A session both sides confirmed at `t0`, the first the initiator: the pair before the first restores.
    private func established() throws -> (RatchetSessionSide, RatchetSessionSide) {
        let (alice, bob) = try RatchetSessionSide.pair()
        #expect(plaintext(try bob.open(alice.seal("hello", now: Self.t0), now: Self.t0)) != nil)
        #expect(plaintext(try alice.open(bob.seal("hello back", now: Self.t0 + 1), now: Self.t0 + 1)) != nil)
        #expect(try #require(alice.session).confirmed)
        return (alice, bob)
    }

    @Test func aResetWithNoSessionIsAFreshFlaggedInit() throws {
        let (alice, bob) = try established()
        alice.wipe()
        let seal = try sealedReset(alice.reset(now: Self.t1))
        #expect(seal.reRooted)
        let header = try #require(seal.envelope.ratchet)
        #expect(header.initial != nil)
        #expect(header.flags == RatchetHeader.resetFlag)
        #expect(try #require(alice.session).lastResetSentAt == Self.t1)
        #expect(plaintext(try bob.open(seal.envelope, now: Self.t1 + 1)) == Self.resetBody)
    }

    /// #85: the heuristic's reset got there first, and the restore's own reset must not mint a second root over it.
    @Test func aSecondResetWhileOursIsUnansweredIsDeclinedAndThePairCarriesOn() throws {
        let (alice, bob) = try established()
        alice.wipe()
        let first = try sealedReset(alice.reset(now: Self.t1))
        #expect(plaintext(try bob.open(first.envelope, now: Self.t1 + 1000)) != nil)
        let root = try #require(alice.session).root

        #expect(isDeclined(try alice.reset(now: Self.t1 + 2000, cause: .afterWipe)))
        #expect(isDeclined(try alice.reset(now: Self.t1 + 2000)))
        #expect(try #require(alice.session).root == root, "the root the peer adopted is still ours")

        #expect(plaintext(try alice.open(bob.seal("re-sealed under your reset", now: Self.t1 + 3000), now: Self.t1 + 3000)) != nil)
        #expect(plaintext(try bob.open(alice.seal("after", now: Self.t1 + 4000), now: Self.t1 + 4000)) != nil)
    }

    @Test func aFlaggedResetStillUnansweredAfterTheFloorReRoots() throws {
        let (alice, bob) = try established()
        alice.wipe()
        _ = try sealedReset(alice.reset(now: Self.t1)) // lost on the way
        #expect(isDeclined(try alice.reset(now: Self.t1 + Self.floor - 1)))
        let second = try sealedReset(alice.reset(now: Self.t1 + Self.floor))
        #expect(second.reRooted)
        #expect(plaintext(try bob.open(second.envelope, now: Self.t1 + Self.floor + 1)) != nil)
    }

    /// #86: a group post opened the session with a plain init; the reset rides that init instead of replacing it.
    @Test func aResetOverOurPlainInitMarksItAndThePeerOpensItAsTheSameSession() throws {
        let (alice, bob) = try established()
        alice.wipe()
        let seed = try alice.seal("seed", now: Self.t1)
        #expect(plaintext(try bob.open(seed, now: Self.t1 + 1000)) != nil)
        let before = try #require(alice.session)
        let peerRoot = try #require(bob.session).root

        let marker = try sealedReset(alice.reset(now: Self.t1 + 5000))
        #expect(!marker.reRooted)
        let header = try #require(marker.envelope.ratchet)
        #expect(header.initial?.eph == seed.ratchet?.initial?.eph, "the same init rides")
        #expect(header.flags == RatchetHeader.resetFlag)
        let after = try #require(alice.session)
        #expect(after.root == before.root, "no second root")
        #expect(after.lastResetSentAt == Self.t1 + 5000)

        #expect(plaintext(try bob.open(marker.envelope, now: Self.t1 + 6000)) == Self.resetBody)
        #expect(try #require(bob.session).root == peerRoot, "the peer stays on the init it adopted")
        #expect(isDeclined(try alice.reset(now: Self.t1 + 7000)), "now a flagged init: once is enough inside the floor")
        #expect(plaintext(try alice.open(bob.seal("reply", now: Self.t1 + 8000), now: Self.t1 + 8000)) != nil)
    }

    @Test func aMarkerIsAdoptedByAPeerThatNeverSawThePlainInit() throws {
        let (alice, bob) = try established()
        alice.wipe()
        _ = try alice.seal("lost on the way", now: Self.t1)
        let marker = try sealedReset(alice.reset(now: Self.t1 + 1000))
        #expect(!marker.reRooted)
        #expect(plaintext(try bob.open(marker.envelope, now: Self.t1 + 2000)) != nil)
        #expect(plaintext(try alice.open(bob.seal("back", now: Self.t1 + 3000), now: Self.t1 + 3000)) != nil)
        #expect(try #require(alice.session).confirmed)
    }

    /// The heuristic's reset: frames that failed to open prove the peer held another session with us, so it took our
    /// init as a replacement, no later than it sealed its answer, and a re-root waits out its floor from there.
    @Test func theHeuristicsResetJustAfterOurInitWasAnsweredWaitsOutThePeersFloor() throws {
        let (alice, bob) = try established()
        alice.wipe()
        #expect(plaintext(try bob.open(alice.seal("seed", now: Self.t1), now: Self.t1 + 1000)) != nil)
        #expect(plaintext(try alice.open(bob.seal("reply", now: Self.t1 + 2000), now: Self.t1 + 3000)) != nil)

        #expect(isDeclined(try alice.reset(now: Self.t1 + 30_000, cause: .unreadable)))
        let reset = try sealedReset(alice.reset(now: Self.t1 + 3000 + Self.floor, cause: .unreadable))
        #expect(reset.reRooted)
        #expect(plaintext(try bob.open(reset.envelope, now: Self.t1 + 4000 + Self.floor)) != nil)
    }

    /// On first contact the peer *established* the session, which starts no floor: an on-demand reset goes out.
    @Test func anOnDemandResetRightAfterFirstContactGoesOut() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        #expect(plaintext(try bob.open(alice.seal("hello", now: Self.t0), now: Self.t0)) != nil)
        #expect(plaintext(try alice.open(bob.seal("hello back", now: Self.t0 + 1000), now: Self.t0 + 1000)) != nil)
        let reset = try sealedReset(alice.reset(now: Self.t0 + 2000))
        #expect(reset.reRooted)
        #expect(plaintext(try bob.open(reset.envelope, now: Self.t0 + 3000)) != nil)
    }

    @Test func afterAWipeAConfirmedSessionGetsTheMarkerWithNoInit() throws {
        let (alice, bob) = try established()
        alice.wipe()
        #expect(plaintext(try bob.open(alice.seal("seed", now: Self.t1), now: Self.t1 + 1000)) != nil)
        #expect(plaintext(try alice.open(bob.seal("reply", now: Self.t1 + 2000), now: Self.t1 + 3000)) != nil)
        let root = try #require(alice.session).root

        let marker = try sealedReset(alice.reset(now: Self.t1 + 4000, cause: .afterWipe))
        #expect(!marker.reRooted)
        let header = try #require(marker.envelope.ratchet)
        #expect(header.initial == nil)
        #expect(header.flags == 0)
        #expect(try #require(alice.session).root == root)
        #expect(plaintext(try bob.open(marker.envelope, now: Self.t1 + 5000)) == Self.resetBody)
        #expect(isDeclined(try alice.reset(now: Self.t1 + 6000, cause: .afterWipe)), "a crash re-run of the restore sends nothing twice")
    }

    @Test func afterAWipeAResponderSessionGetsTheMarker() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        #expect(plaintext(try alice.open(bob.seal("hello", now: Self.t0), now: Self.t0)) != nil)
        let marker = try sealedReset(alice.reset(now: Self.t0 + 1000, cause: .afterWipe))
        #expect(!marker.reRooted)
        #expect(try #require(marker.envelope.ratchet).initial == nil)
        #expect(plaintext(try bob.open(marker.envelope, now: Self.t0 + 2000)) != nil)
    }

    @Test func afterAWipeAPendingInitAgainstARetiredPrekeyIsReplaced() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        bob.prekeys[2] = try SignedPrekey.mint(id: 2, signedBy: bob.identity, createdAt: 0)
        _ = try alice.seal("to the old prekey", now: Self.t0)
        let reset = try sealedReset(alice.reset(now: Self.t0 + 1000, cause: .afterWipe, pkid: 2))
        #expect(reset.reRooted)
        #expect(try #require(reset.envelope.ratchet).initial?.pkid == 2)
        #expect(plaintext(try bob.open(reset.envelope, now: Self.t0 + 2000)) != nil)
    }

    // MARK: #135: an old-era frame drained after a reset never decides the resetter's new era

    /// #135 as the P3 to P7 pair hit it. After the reset, custody re-served an old-era frame of the resetter's epoch 4 that
    /// the peer holds no message row for (a receipt), so it reached the ratchet, opened under the kept `prevRoot`, and
    /// stored its chain. The restarted numbering then reached 4: its frames must open, not land on the old era's chain
    /// index (`DUPLICATE`) or its key (`AEAD_FAIL`).
    @Test func anOldEraFrameDrainedAfterAResetNeverDecidesTheNewEpochOfTheSameNumber() throws {
        let (alice, bob) = try established()
        let old4 = try advance(alice, to: bob, se: 4, start: Self.t0 + 10)
        #expect(plaintext(try alice.open(bob.seal("answer", now: Self.t0 + 100), now: Self.t0 + 100)) != nil)

        #expect(plaintext(try bob.open(sealedReset(alice.reset(now: Self.t1)).envelope, now: Self.t1)) != nil)
        #expect(plaintext(try bob.open(old4, now: Self.t1 + 1000)) != nil, "the re-serve, under prevRoot")
        #expect(plaintext(try alice.open(bob.seal("answer the reset", now: Self.t1 + 2000), now: Self.t1 + 2000)) != nil)

        let new4 = try advance(alice, to: bob, se: 4, start: Self.t1 + 3000)
        #expect(new4.ratchet?.n == 0)
        #expect(plaintext(try bob.open(alice.seal("new era, epoch 4, n=1", now: Self.t1 + 4000), now: Self.t1 + 4000)) != nil)
    }

    /// #135 as the P9 to P8 pair hit it: the re-served old-era frames sat mid-epoch, so opening them under `prevRoot`
    /// banked skipped keys for the indices below. The new era's n=0 then met a stale skipped key, a rung that returned its
    /// own AEAD failure without trying anything else.
    @Test func aStaleSkippedKeyFromADrainedOldEraNeverDecidesTheNewEpoch() throws {
        let (alice, bob) = try established()
        _ = try advance(alice, to: bob, se: 2, start: Self.t0 + 10)
        let mid = try (1...3).map { try alice.seal("old era, epoch 2, n=\($0)", now: Self.t0 + 50 + Int64($0)) }
        for frame in mid {
            #expect(plaintext(try bob.open(frame, now: Self.t0 + 60)) != nil)
        }
        #expect(plaintext(try alice.open(bob.seal("answer", now: Self.t0 + 100), now: Self.t0 + 100)) != nil)

        #expect(plaintext(try bob.open(sealedReset(alice.reset(now: Self.t1)).envelope, now: Self.t1)) != nil)
        for frame in mid.dropFirst() {
            #expect(plaintext(try bob.open(frame, now: Self.t1 + 1000)) != nil, "n=2 and n=3 re-served: keys banked for 0 and 1")
        }
        #expect(plaintext(try alice.open(bob.seal("answer the reset", now: Self.t1 + 2000), now: Self.t1 + 2000)) != nil)

        _ = try advance(alice, to: bob, se: 2, start: Self.t1 + 3000)
        #expect(plaintext(try bob.open(alice.seal("new era, epoch 2, n=1", now: Self.t1 + 4000), now: Self.t1 + 4000)) != nil)
    }

    /// Drives `from` to send epoch `se` and answers that epoch's n=0, which `to` must open; `to` answers every epoch below
    /// it, so the healing rule moves `from` one epoch per turnaround (`advanceTo`, `RatchetSessionsResetTest.kt:288-307`).
    private func advance(_ from: RatchetSessionSide, to: RatchetSessionSide, se: Int, start: Int64) throws -> EncEnvelope {
        var now = start
        for _ in 0..<64 {
            let envelope = try from.seal("epoch at \(now)", now: now)
            #expect(plaintext(try to.open(envelope, now: now)) != nil)
            now += 1
            if try #require(envelope.ratchet).se == se {
                return envelope
            }
            #expect(plaintext(try from.open(to.seal("answer at \(now)", now: now), now: now)) != nil)
            now += 1
        }
        Issue.record("epoch \(se) never came")
        throw RatchetSessionSide.Unexpected()
    }
}
