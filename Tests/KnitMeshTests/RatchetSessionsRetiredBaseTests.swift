import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The retired-base rule (knit-next ADR 2026-10.9wvr): an `EPOCH_GONE` sealed against one of our local epochs that
/// retention already retired, behind an epoch the peer has since sealed against, is doomed ciphertext and never reset
/// evidence. knit-next's `RatchetSessionsRetiredBaseTest` (`09cacf5b`, at `4f3cd995`) case by case under its Kotlin names:
/// the rule's table on the pure function, and the pair cases on two real facades, so the frame that fails is one the peer
/// really sealed, held back while the pair kept talking, and judged after the real retention sweep. Kotlin's
/// `SessionTransactorOrderTest` case for `retiredBase` has no counterpart: this port takes no lock, and the read is one
/// store unit (ADR 2026-10.5sk9's P4a amendment).
@Suite struct RatchetSessionsRetiredBaseTests {
    static let start: Int64 = 10 * 3_600_000
    static let minute: Int64 = 60_000

    /// One DM each way, each opened: a turnaround moves each side's send epoch by one (the healing rule).
    private func turn(_ alice: RatchetSessionSide, _ bob: RatchetSessionSide, now: Int64) throws {
        #expect(plaintext(try bob.open(alice.seal("alice at \(now)", now: now), now: now)) != nil)
        #expect(plaintext(try alice.open(bob.seal("bob at \(now)", now: now), now: now)) != nil)
    }

    private struct Held {
        let frame: EncEnvelope
        let base: Int
        let now: Int64
    }

    /// The field's shape on Alice's side: Bob seals the held frame as the first of a fresh epoch, based on Alice's newest;
    /// it never reaches her, while his next epoch does (his first ages out a day on), and enough turnarounds follow for the
    /// 16-row cap to retire the epoch it was based on.
    private func heldPastTheCap(_ alice: RatchetSessionSide, _ bob: RatchetSessionSide) throws -> Held {
        var now = Self.start
        for _ in 0..<2 {
            try turn(alice, bob, now: now)
            now += Self.minute
        }
        #expect(plaintext(try bob.open(alice.seal("alice before the hold", now: now), now: now)) != nil)
        let held = try bob.seal("held by a carrier", now: now)
        let base = try #require(held.ratchet).pe
        #expect(alice.session?.sendEpoch == base, "the held frame is based on Alice's newest epoch")
        now += RatchetEngine.maxEpochAgeMilliseconds
        // A day on, Bob's epoch has aged out: his next seal opens another, so Alice never derives the held one's.
        let after = try bob.seal("bob a day later", now: now)
        #expect(after.ratchet?.se == (held.ratchet?.se ?? 0) + 1)
        #expect(plaintext(try alice.open(after, now: now)) != nil)
        for _ in 0..<RatchetRetention.maxLocalEpochs {
            now += Self.minute
            try turn(alice, bob, now: now)
        }
        #expect(alice.sessions.sweep(now: now))
        #expect(alice.store.localEpochPrivateKey(bob.nodeId, epoch: base) == nil, "the cap retired the held frame's base")
        return Held(frame: held, base: base, now: now)
    }

    @Test func theRuleRetiresOnlyAnEpochBelowBothTheLowestHeldAndThePeersNewest() {
        let rule = RatchetResetPolicy.isRetiredBase
        #expect(rule(5, 20, 12), "below both: swept, and the peer has sealed past it")
        #expect(!rule(12, 20, 12), "the lowest held epoch is not retired")
        #expect(!rule(15, 20, 12), "a hole above the lowest held is the split-era case")
        #expect(!rule(25, 20, 12), "past our newest is another era's numbering")
        #expect(!rule(5, 5, 12), "a peer still based on an epoch the cap evicted is live: its newest seal against us is that epoch")
        #expect(!rule(5, 3, 12), "the peer never sealed past it")
        #expect(!rule(0, 20, 12), "pe 0 is our signed prekey, never a retired epoch")
    }

    @Test func aFrameSealedAgainstAnEpochTheCapRetiredIsDoomedNotEvidence() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let held = try heldPastTheCap(alice, bob)

        guard case .settled(.refused(.epochGone)) = try alice.open(held.frame, now: held.now) else {
            Issue.record("the held frame fails as EPOCH_GONE")
            return
        }
        let verdict = try #require(alice.sessions.retiredBase(from: bob.nodeId, pe: held.base), "the held frame read as evidence")
        #expect(held.base < verdict.lowestRetained, "below every epoch Alice still holds")
        #expect(held.base < verdict.highestPeAcked, "and behind an epoch Bob has sealed against since")
        #expect(
            !alice.sessions.noteUndecryptable(from: bob.nodeId, frameId: "held", sentAt: held.now, now: held.now, epochGoneBase: held.base))
        #expect(alice.sessions.floors(for: bob.nodeId).undecryptableIds == 0, "never a slot among the heuristic's ids")

        // The session it would have re-rooted is working: Bob's next frame opens.
        #expect(plaintext(try alice.open(bob.seal("still talking", now: held.now), now: held.now)) != nil)
    }

    @Test func anEpochAtOrAboveTheLowestHeldStillCounts() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let held = try heldPastTheCap(alice, bob)
        let lowest = try #require(alice.store.lowestLocalEpoch(bob.nodeId))
        let newest = try #require(alice.session).sendEpoch

        // A hole above the lowest: every row but that one, put back.
        let records = alice.store.records(of: bob.nodeId)
        let session = try #require(records.session)
        alice.store.deletePeer(bob.nodeId)
        alice.store.upsertSession(session)
        for epoch in records.localEpochs where epoch.epoch != lowest + 1 {
            alice.store.commitSend(session, newLocalEpoch: epoch)
        }
        #expect(
            alice.sessions.retiredBase(from: bob.nodeId, pe: lowest + 1) == nil,
            "a hole above the lowest held epoch is not ours to explain away")
        #expect(alice.sessions.retiredBase(from: bob.nodeId, pe: newest + 1) == nil, "an epoch we never minted in this numbering")
        #expect(alice.sessions.retiredBase(from: bob.nodeId, pe: 0) == nil, "the signed prekey")
        #expect(alice.sessions.retiredBase(from: bob.nodeId, pe: held.base) != nil, "while the held frame's base still reads as retired")
    }

    @Test func ourOwnResetShutsTheRuleUntilThePeerSealsUnderTheNewRoot() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let held = try heldPastTheCap(alice, bob)

        let reset = try sealedReset(alice.reset(now: held.now))
        #expect(reset.reRooted, "alice re-rooted")
        // A reset restarts our numbering at 1 and its fresh initiation knows of no ack: nothing we can still read in this
        // numbering says the peer has moved past an epoch, so every EPOCH_GONE counts again.
        #expect(alice.session?.highestPeAcked == 0)
        #expect(alice.sessions.retiredBase(from: bob.nodeId, pe: held.base) == nil)
    }

    /// A read the store fails answers no verdict, and changes nothing: the next read that succeeds gives the verdict the
    /// rows held all along. This is the diagnostic read; the engine's own gate, `noteUndecryptable`, counts nothing when
    /// its read fails.
    @Test func aReadTheStoreFailsAnswersNoVerdict() throws {
        let refusing = RefusingRatchetStore()
        let (alice, bob) = try RatchetSessionSide.pair(refusing: refusing)
        let held = try heldPastTheCap(alice, bob)
        let records = refusing.held.records(of: bob.nodeId)

        refusing.refuse(.reads)
        #expect(alice.sessions.retiredBase(from: bob.nodeId, pe: held.base) == nil, "a failed read is no verdict")
        refusing.refuse([])
        #expect(refusing.held.records(of: bob.nodeId) == records, "and moved nothing")
        #expect(alice.sessions.retiredBase(from: bob.nodeId, pe: held.base) != nil, "the next read gives the verdict")
    }

    @Test func noSessionIsNeverRetired() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        #expect(alice.sessions.retiredBase(from: bob.nodeId, pe: 3) == nil, "no session, nothing to protect: a reset is the only answer")
    }
}
