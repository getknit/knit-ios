import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The floors the session facade holds in memory and the reset heuristic's count (`RatchetSessions.kt:97-111`,
/// `:279-311`): they move only once their unit commits, save the heuristic's ids, which a counted frame joins at once,
/// they die with the process, and the reset floor reads the persisted stamp inside a unit. The era gate in front of the
/// count is `RatchetSessionsEvidenceTests`'.
@Suite struct RatchetSessionsFloorTests {
    static let t0: Int64 = 100_000_000
    static let t1 = t0 + 600_000
    static let aad = RatchetSessionSide.aad
    static let resetFloor = RatchetResetPolicy.resetMilliseconds

    private func established() throws -> (RatchetSessionSide, RatchetSessionSide) {
        let (alice, bob) = try RatchetSessionSide.pair()
        #expect(plaintext(try bob.open(alice.seal("hello", now: Self.t0), now: Self.t0)) != nil)
        #expect(plaintext(try alice.open(bob.seal("hello back", now: Self.t0 + 1), now: Self.t0 + 1)) != nil)
        return (alice, bob)
    }

    /// The receiver's floor (knit-next ADR 023): an incidental init replaces a session only an hour after the last
    /// replacement, and one flagged `FLAG_RESET` a minute after.
    @Test func anUnflaggedReplacementWaitsAnHourAndAFlaggedOneAMinute() throws {
        let (alice, bob) = try established()
        alice.wipe()
        #expect(plaintext(try bob.open(alice.seal("first", now: Self.t1), now: Self.t1)) != nil)
        #expect(bob.sessions.floors(for: alice.nodeId).lastReplacementAt == Self.t1)
        let adopted = try #require(bob.session)

        alice.wipe()
        let unflagged = try alice.seal("second", now: Self.t1 + 1000)
        guard case .settled(.refused) = try bob.open(unflagged, now: Self.t1 + RatchetResetPolicy.replacementMilliseconds - 1) else {
            Issue.record("an unflagged init inside the hour is not adopted")
            return
        }
        #expect(bob.session?.root == adopted.root)

        let marker = try sealedReset(alice.reset(now: Self.t1 + 2000))
        #expect(!marker.reRooted, "the init it holds is pending and plain, so it is marked")
        guard case .settled(.refused) = try bob.open(marker.envelope, now: Self.t1 + RatchetResetPolicy.resetReplacementMilliseconds - 1)
        else {
            Issue.record("a flagged init inside the minute is not adopted")
            return
        }
        #expect(plaintext(try bob.open(marker.envelope, now: Self.t1 + RatchetResetPolicy.resetReplacementMilliseconds)) != nil)
        #expect(bob.session?.root != adopted.root)
    }

    @Test func confirmedAtIsStampedWhenThePeerAnswersOurInitAndARaceLostStampsTheReplacementFloor() throws {
        let (alice, bob) = try established()
        #expect(alice.sessions.floors(for: bob.nodeId).confirmedAt == Self.t0 + 1)
        #expect(bob.sessions.floors(for: alice.nodeId).confirmedAt == nil, "a responder answered no init of its own")

        let (carol, dave) = try RatchetSessionSide.pair()
        let carolsInit = try carol.seal("carol first", now: Self.t0)
        let davesInit = try dave.seal("dave first", now: Self.t0)
        let (winner, loser, winnersInit) = carol.nodeId < dave.nodeId ? (carol, dave, carolsInit) : (dave, carol, davesInit)
        #expect(plaintext(try loser.open(winnersInit, now: Self.t0 + 5)) != nil)
        let lost = loser.sessions.floors(for: winner.nodeId)
        #expect(lost.lastReplacementAt == Self.t0 + 5 && lost.confirmedAt == nil, "a lost race confirms us as responder")
    }

    @Test func noteUndecryptableCountsThreeDistinctIdsAmongTheLastEight() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let peer = bob.nodeId
        let sessions = alice.sessions
        #expect(!sessions.noteUndecryptable(from: peer, frameId: "K", sentAt: Self.t0, now: Self.t0))
        #expect(!sessions.noteUndecryptable(from: peer, frameId: "K", sentAt: Self.t0, now: Self.t0), "one stuck frame, re-served")
        #expect(
            !sessions.noteUndecryptable(from: peer, frameId: "\u{212A}", sentAt: Self.t0, now: Self.t0), "the Kelvin sign is another id")
        #expect(sessions.noteUndecryptable(from: peer, frameId: "c", sentAt: Self.t0, now: Self.t0))
        for id in ["d", "e", "f", "g", "h", "i"] {
            _ = sessions.noteUndecryptable(from: peer, frameId: id, sentAt: Self.t0, now: Self.t0)
        }
        #expect(sessions.floors(for: peer).undecryptableIds == RatchetResetPolicy.trackedFrames)
        #expect(sessions.floors(for: fixtureNodeId(9)).undecryptableIds == 0, "per peer")
    }

    @Test func theResetFloorReadsThePersistedStampWhichOutlivesARestartAndTheOneInMemory() throws {
        let (alice, bob) = try established()
        _ = try sealedReset(alice.reset(now: Self.t1))
        let peer = bob.nodeId
        // Every frame here is live: sealed by the peer just after our reset, inside the era the reset began.
        let live = Self.t1 + 1
        for id in ["a", "b"] {
            _ = alice.sessions.noteUndecryptable(from: peer, frameId: id, sentAt: live, now: Self.t1 + 1)
        }
        #expect(!alice.sessions.noteUndecryptable(from: peer, frameId: "c", sentAt: live, now: Self.t1 + Self.resetFloor - 1))
        #expect(alice.sessions.noteUndecryptable(from: peer, frameId: "d", sentAt: live, now: Self.t1 + Self.resetFloor))

        // A restart forgets the floors in memory, and the session row still holds the stamp.
        let restarted = RatchetSessions(identity: alice.identity, store: alice.store, transactor: alice.transactor)
        for id in ["a", "b"] {
            _ = restarted.noteUndecryptable(from: peer, frameId: id, sentAt: live, now: Self.t1 + 1)
        }
        #expect(restarted.floors(for: peer).lastResetSentAt == nil)
        #expect(!restarted.noteUndecryptable(from: peer, frameId: "c", sentAt: live, now: Self.t1 + Self.resetFloor - 1))

        // With no session row, the stamp held in memory floors the reset instead.
        alice.wipe()
        #expect(!alice.sessions.noteUndecryptable(from: peer, frameId: "e", sentAt: live, now: Self.t1 + Self.resetFloor - 1))
        #expect(alice.sessions.noteUndecryptable(from: peer, frameId: "f", sentAt: live, now: Self.t1 + Self.resetFloor))
    }

    @Test func aCommittedResetClearsTheHeuristicsIdsAndOurInitsAnswer() throws {
        let (alice, bob) = try established()
        let peer = bob.nodeId
        _ = alice.sessions.noteUndecryptable(from: peer, frameId: "a", sentAt: Self.t1, now: Self.t1)
        #expect(
            alice.sessions.floors(for: peer)
                == .init(lastReplacementAt: nil, confirmedAt: Self.t0 + 1, lastResetSentAt: nil, undecryptableIds: 1))
        _ = try sealedReset(alice.reset(now: Self.t1))
        #expect(
            alice.sessions.floors(for: peer)
                == .init(lastReplacementAt: nil, confirmedAt: nil, lastResetSentAt: Self.t1, undecryptableIds: 0))
    }

    @Test func aResetInsideACallersUnitHandsItsFloorsUpAndOneWhoseStoreFailsMovesNone() throws {
        let refusing = RefusingRatchetStore()
        let (alice, bob) = try RatchetSessionSide.pair(refusing: refusing)
        let prekey = try alice.prekey()
        var inner: RatchetSessions.Answer<RatchetSessions.ResetSealing>?
        let outer = alice.transactor.atomically { () -> Int? in
            inner = alice.sessions.sealResetDm(
                to: bob.identity.bundle, prekey: prekey, plaintext: RatchetSessions.resetPlaintext, aad: Self.aad, now: Self.t0)
            return 1
        }
        #expect(outer == .committed(1))
        guard case .joined(.sealed, let settlement) = inner else {
            Issue.record("a reset inside a caller's unit joins it: \(String(describing: inner))")
            return
        }
        #expect(alice.sessions.floors(for: bob.nodeId).lastResetSentAt == nil)
        alice.sessions.settle(settlement)
        #expect(alice.sessions.floors(for: bob.nodeId).lastResetSentAt == Self.t0)

        refusing.refuse(.writes)
        let later = Self.t0 + Self.resetFloor
        let failed = alice.sessions.sealResetDm(to: bob.identity.bundle, prekey: prekey, plaintext: [1], aad: Self.aad, now: later)
        #expect(failed == .failed)
        #expect(alice.sessions.floors(for: bob.nodeId).lastResetSentAt == Self.t0, "no floor moved")
    }

    @Test func aResetWithNoPrekeyOrUnderASessionMissingItsInitSealsNothing() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let none = alice.sessions.sealResetDm(to: bob.identity.bundle, prekey: nil, plaintext: [1], aad: Self.aad, now: Self.t0)
        #expect(none == .settled(.noPrekey))
        // Only a damaged row holds a pending init of ours without its ephemeral; the marker cannot ride it.
        let damaged = RatchetSessionRecord(
            peerId: bob.nodeId,
            confirmed: false,
            weAreInitiator: true,
            root: [UInt8](repeating: 1, count: 32),
            establishedAt: Self.t0,
            initPkid: 1,
            sendEpoch: 1,
            sendEpochPub: [UInt8](repeating: 2, count: 32),
            sendChainKey: [UInt8](repeating: 3, count: 32),
            sendEpochStartedAt: Self.t0
        )
        alice.store.upsertSession(damaged)
        let marked = alice.sessions.sealResetDm(
            to: bob.identity.bundle, prekey: try alice.prekey(), plaintext: [1], aad: Self.aad, now: Self.t0 + 1)
        #expect(marked == .settled(.noPrekey))
        #expect(alice.store.session(bob.nodeId) == damaged)
    }

    @Test func forgetDropsEveryRowAndSaysWhetherThereWasASession() throws {
        let refusing = RefusingRatchetStore()
        let (alice, bob) = try RatchetSessionSide.pair(refusing: refusing)
        #expect(plaintext(try bob.open(alice.seal("hello", now: Self.t0), now: Self.t0)) != nil)
        #expect(plaintext(try alice.open(bob.seal("back", now: Self.t0), now: Self.t0)) != nil)
        refusing.refuse(.writes)
        #expect(alice.sessions.forget(bob.nodeId) == .failed)
        refusing.refuse([])
        #expect(alice.sessions.floors(for: bob.nodeId).confirmedAt == Self.t0)

        var inner: RatchetSessions.Answer<Bool>?
        _ = alice.transactor.atomically { () -> Int? in
            inner = alice.sessions.forget(bob.nodeId)
            return nil
        }
        guard case .joined(true, let settlement) = inner else {
            Issue.record("a forget inside a caller's unit joins it")
            return
        }
        #expect(alice.session != nil, "the caller's unit took the forget with it")
        alice.sessions.settle(settlement)
        #expect(alice.sessions.floors(for: bob.nodeId).confirmedAt == nil)

        #expect(alice.sessions.forget(bob.nodeId) == .settled(true))
        #expect(alice.store.records(of: bob.nodeId) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
        #expect(alice.sessions.forget(bob.nodeId) == .settled(false))
    }

    @Test func sweepRunsInAUnitAndSaysWhetherItStood() throws {
        let refusing = RefusingRatchetStore()
        let (alice, bob) = try RatchetSessionSide.pair(refusing: refusing)
        _ = try alice.seal("hello", now: Self.t0)
        #expect(alice.sessions.sweep(now: Self.t0 + RatchetRetention.localEpochLifetimeMilliseconds))
        #expect(alice.sessions.localEpochs(of: bob.nodeId).map(\.epoch) == [1], "the newest three always stay")
        refusing.refuse(.writes)
        #expect(!alice.sessions.sweep(now: Self.t0))
    }

    @Test func theResetPlaintextIsTheNamedV2Marker() throws {
        let content = try MessageContent(decoding: RatchetSessions.resetPlaintext)
        #expect(content == MessageContent(body: "", ctl: MessageContent.Control.sessionReset))
    }
}
