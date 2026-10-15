import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The session facade's store units (ADR 2026-10.5sk9's P4a contract): a seal persists its chain before the frame is
/// answered, an open's changes stand with the caller's writes or not at all, a store that fails answers ``failed`` with
/// nothing used, and a call inside a caller's unit answers ``joined`` and leaves its floors to ``settle(_:)``.
@Suite struct RatchetSessionsTests {
    static let now: Int64 = 1_700_000_000_000
    static let aad = RatchetSessionSide.aad
    static let lowOrderPoint = [UInt8](repeating: 0, count: RatchetCrypto.keyByteCount)

    // MARK: Sealing

    @Test func aSealIsPersistedWithItsChainBeforeItIsAnswered() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let first = try alice.seal("one", now: Self.now)
        let stored = try #require(alice.store.session(bob.nodeId))
        #expect(stored.sendEpoch == 1 && stored.sendCount == 1 && !stored.confirmed && stored.initEphPub != nil)
        #expect(alice.store.records(of: bob.nodeId).localEpochs.map(\.epoch) == [1], "the epoch the initiation minted")
        #expect(first.version == EncEnvelope.Version.ratchet && first.nonce.count == RatchetCrypto.nonceByteCount && first.keys.isEmpty)
        let compact = try alice.seal("two", now: Self.now, v3: true)
        #expect(compact.version == EncEnvelope.Version.compactRatchet && compact.nonce.isEmpty, "v3's nonce derives, and rides empty")
        #expect(try #require(alice.store.session(bob.nodeId)).sendCount == 2)
        #expect(plaintext(try bob.open(first, now: Self.now)) == Array("one".utf8))
        #expect(plaintext(try bob.open(compact, now: Self.now)) == Array("two".utf8))
    }

    @Test func withNoSessionAndNoPrekeyNothingIsSealed() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let answer = alice.sessions.sealDm(to: bob.identity.bundle, prekey: nil, plaintext: [1], aad: Self.aad, now: Self.now)
        #expect(answer == .settled(.unavailable))
        #expect(alice.store.session(bob.nodeId) == nil)
    }

    /// An established session whose peer has cleared its prekey and contributed no epoch (`RatchetSessions.kt:232-234`).
    @Test func aNewEpochDueWithNoBaseSealsNothing() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let held = RatchetSessionRecord(
            peerId: bob.nodeId, confirmed: true, weAreInitiator: false, root: [UInt8](repeating: 1, count: 32), establishedAt: 1)
        alice.store.upsertSession(held)
        let answer = alice.sessions.sealDm(to: bob.identity.bundle, prekey: nil, plaintext: [1], aad: Self.aad, now: Self.now)
        #expect(answer == .settled(.unavailable))
        #expect(alice.store.session(bob.nodeId) == held, "nothing moved")
    }

    /// A peer signs what it likes, so a signature rules out no key X25519 refuses: nothing is sealed or committed, and
    /// nothing counts toward a reset (the P4b review).
    @Test func aPrekeyX25519RefusesSealsNothing() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let signature = try bob.identity.signature(for: RatchetCrypto.spkSigningBytes(id: 1, pub: Self.lowOrderPoint))
        let refused = try #require(
            PeerPrekey(verifying: PrekeyInfo(id: 1, pub: Self.lowOrderPoint, sig: signature), signedBy: bob.identity.bundle))
        let bundle = bob.identity.bundle
        #expect(alice.sessions.sealDm(to: bundle, prekey: refused, plaintext: [1], aad: Self.aad, now: Self.now) == .settled(.refusedKey))
        #expect(
            alice.sessions.sealResetDm(to: bundle, prekey: refused, plaintext: [1], aad: Self.aad, now: Self.now) == .settled(.refusedKey))
        #expect(alice.store.session(bob.nodeId) == nil)
        #expect(alice.sessions.floors(for: bob.nodeId).lastResetSentAt == nil)
    }

    @Test func aSealInsideACallersUnitStandsOnlyOnceThatUnitCommits() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let prekey = try alice.prekey()
        var inner: RatchetSessions.Answer<RatchetSessions.Sealing>?
        let abandoned = alice.transactor.atomically { () -> Int? in
            inner = alice.sessions.sealDm(to: bob.identity.bundle, prekey: prekey, plaintext: [1], aad: Self.aad, now: Self.now)
            return nil
        }
        #expect(abandoned == .abandoned)
        guard case .joined(.sealed, _) = inner else {
            Issue.record("a seal inside a caller's unit joins it: \(String(describing: inner))")
            return
        }
        #expect(alice.store.session(bob.nodeId) == nil, "the chain went with the caller's unit, so the frame never may")
        let committed = alice.transactor.atomically { () -> RatchetSessions.Answer<RatchetSessions.Sealing>? in
            alice.sessions.sealDm(to: bob.identity.bundle, prekey: prekey, plaintext: [1], aad: Self.aad, now: Self.now)
        }
        guard case .committed(.joined(.sealed(let envelope), _)) = committed else {
            Issue.record("expected a joined seal under a committed unit, got \(committed)")
            return
        }
        #expect(try #require(alice.store.session(bob.nodeId)).sendCount == 1)
        #expect(plaintext(try bob.open(envelope, now: Self.now)) == [1])
    }

    @Test func aSealWhoseStoreFailsAnswersFailedAndPersistsNothing() throws {
        let refusing = RefusingRatchetStore()
        let (alice, bob) = try RatchetSessionSide.pair(refusing: refusing)
        let prekey = try alice.prekey()
        for refusal in [RefusingRatchetStore.Refusals.writes, .reads] {
            refusing.refuse(refusal)
            #expect(alice.sessions.sealDm(to: bob.identity.bundle, prekey: prekey, plaintext: [1], aad: Self.aad, now: Self.now) == .failed)
            refusing.refuse([])
            #expect(alice.store.session(bob.nodeId) == nil, "\(refusal): nothing persisted")
        }
    }

    // MARK: Opening

    @Test func anOpensChangesCommitWithTheCallersWritesOrNotAtAll() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let store = MemoryRatchetStore()
        let threads = MemoryConversationStore()
        let unit = MemoryTransactor(stores: [store, threads])
        let sessions = RatchetSessions(identity: bob.identity, store: store, transactor: unit)
        let frame = try #require(RatchetSessions.Frame(envelope: alice.seal("hi", now: Self.now), aad: Self.aad))
        let prekeys = bob.prekeys

        let abandoned = sessions.open(
            frame,
            from: alice.identity.bundle,
            now: Self.now,
            prekeys: { prekeys[$0] },
            alongside: { _ -> [UInt8]? in
                threads.accept("thread")
                return nil
            }
        )
        guard case .settled(.abandoned) = abandoned else {
            Issue.record("the caller's nil abandons the unit: \(abandoned)")
            return
        }
        #expect(store.session(alice.nodeId) == nil && threads.acceptedConversations().isEmpty, "the open went with the caller's row")

        let opened = sessions.open(
            frame,
            from: alice.identity.bundle,
            now: Self.now,
            prekeys: { prekeys[$0] },
            alongside: { opened -> [UInt8]? in
                threads.accept("thread")
                return opened.plaintext
            }
        )
        guard case .settled(.opened(let text, let work)) = opened else {
            Issue.record("expected the frame to open, got \(opened)")
            return
        }
        #expect(text == Array("hi".utf8) && work == text, "the caller's work comes back with the plaintext")
        #expect(store.session(alice.nodeId)?.confirmed == true)
        #expect(threads.acceptedConversations() == ["thread"])
    }

    @Test func anOpenWhoseStoreFailsDeliversNothingMovesNoFloorAndOpensOnReplay() throws {
        let refusing = RefusingRatchetStore()
        let (bob, alice) = try RatchetSessionSide.pair(refusing: refusing)
        #expect(plaintext(try bob.open(alice.seal("hello", now: Self.now), now: Self.now)) != nil)
        #expect(plaintext(try alice.open(bob.seal("back", now: Self.now + 1), now: Self.now + 1)) != nil)
        let held = bob.session
        alice.wipe()
        let replacement = try alice.seal("again", now: Self.now + 10)

        refusing.refuse(.writes)
        guard case .failed = try bob.open(replacement, now: Self.now + 20) else {
            Issue.record("a refused write fails the open")
            return
        }
        refusing.refuse([])
        #expect(bob.session == held, "the session, chain and purge went with the unit")
        #expect(bob.sessions.floors(for: alice.nodeId).lastReplacementAt == nil, "no floor moved")

        // The frame is in our own custody, so P5 replays it from there: it opens, and only now the floor starts.
        #expect(plaintext(try bob.open(replacement, now: Self.now + 30)) == Array("again".utf8))
        #expect(bob.sessions.floors(for: alice.nodeId).lastReplacementAt == Self.now + 30)
    }

    @Test func anOpenInsideACallersUnitHandsItsFloorsUp() throws {
        let (bob, alice) = try RatchetSessionSide.pair()
        #expect(plaintext(try bob.open(alice.seal("hello", now: Self.now), now: Self.now)) != nil)
        alice.wipe()
        let frame = try #require(RatchetSessions.Frame(envelope: alice.seal("again", now: Self.now + 10), aad: Self.aad))
        let prekeys = bob.prekeys
        let held = bob.session
        for commits in [false, true] {
            var inner: RatchetSessions.Answer<RatchetSessions.Opening<Void>>?
            let outer = bob.transactor.atomically { () -> Int? in
                inner = bob.sessions.open(
                    frame, from: alice.identity.bundle, now: Self.now + 20, prekeys: { prekeys[$0] }, alongside: { _ in () })
                return commits ? 1 : nil
            }
            guard case .joined(.opened, let settlement) = inner else {
                Issue.record("an open inside a caller's unit joins it: \(String(describing: inner))")
                return
            }
            #expect(bob.sessions.floors(for: alice.nodeId).lastReplacementAt == nil, "nothing moves before the caller settles")
            if commits {
                #expect(outer == .committed(1))
                bob.sessions.settle(settlement)
                #expect(bob.sessions.floors(for: alice.nodeId).lastReplacementAt == Self.now + 20)
                #expect(bob.session?.establishedAt == Self.now + 10, "the replacement stands")
            } else {
                #expect(outer == .abandoned)
                #expect(bob.session == held, "the caller's unit took the replacement with it")
            }
        }
    }

    @Test func aRefusalOrARejectionChangesNothing() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let first = try alice.seal("hi", now: Self.now)
        #expect(plaintext(try bob.open(first, now: Self.now)) != nil)
        guard case .settled(.refused(.duplicate)) = try bob.open(first, now: Self.now) else {
            Issue.record("a re-serve of a spent index is a duplicate")
            return
        }
        // A low-order init ephemeral: Tink throws in the X3DH respond, and the frame counts for nothing.
        let (carol, dave) = try RatchetSessionSide.pair()
        var spoiled = try carol.seal("hi", now: Self.now)
        spoiled.ratchet?.initial?.eph = Self.lowOrderPoint
        guard case .settled(.rejected) = try dave.open(spoiled, now: Self.now) else {
            Issue.record("a low-order init.eph is rejected, never a typed failure")
            return
        }
        #expect(dave.session == nil)
    }

    /// The engine trusts the prekey it is handed, so the facade hands it only the one the init names (the P4b review;
    /// `RatchetSessions.kt:140`). Under another id it is none: `EPOCH_GONE`, never a wrong root's `AEAD_FAIL`.
    @Test func theInitsPrekeyIsOnlyTheOneItsIdNames() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let frame = try #require(RatchetSessions.Frame(envelope: alice.seal("hi", now: Self.now), aad: Self.aad))
        let other = try SignedPrekey.mint(id: 2, signedBy: bob.identity, createdAt: 0)
        let answer = bob.sessions.open(frame, from: alice.identity.bundle, now: Self.now, prekeys: { _ in other }, alongside: { _ in () })
        guard case .settled(.refused(.epochGone)) = answer else {
            Issue.record("expected EPOCH_GONE, got \(answer)")
            return
        }
    }

    @Test func aFrameIsReadFromAV2OrV3EnvelopeOnly() throws {
        let (alice, _) = try RatchetSessionSide.pair()
        let v2 = try alice.seal("two", now: Self.now)
        let v3 = try alice.seal("three", now: Self.now, v3: true)
        #expect(RatchetSessions.Frame(envelope: v2, aad: Self.aad)?.nonce == v2.nonce)
        #expect(RatchetSessions.Frame(envelope: v3, aad: Self.aad)?.nonce == nil, "v3's nonce derives")
        #expect(RatchetSessions.Frame(envelope: v3, aad: Self.aad)?.header == v3.ratchet)
        var v1 = v2
        v1.version = EncEnvelope.Version.staticKeys
        #expect(RatchetSessions.Frame(envelope: v1, aad: Self.aad) == nil)
        var bare = v2
        bare.ratchet = nil
        #expect(RatchetSessions.Frame(envelope: bare, aad: Self.aad) == nil)
    }
}
