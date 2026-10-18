import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// `RatchetSessions.sealDm` and `sealResetDm` when they cannot seal (#172), and the prekey an unconfirmed session's epochs
/// are based on (#174): knit-next's `RatchetSessionsSealTest` (`458c2eee`, at `4f3cd995`), case by case under its Kotlin
/// names. Two real facades, one per side, as in ``RatchetSessionsResetTests``: what one side sealed and whether the other
/// opens it. Where Kotlin answers `null` or `ResetSeal.NoPrekey`, this port answers ``RatchetSessions/Sealing/refusedKey``
/// or ``RatchetSessions/ResetSealing/refusedKey``, which every caller handles as having no prekey (ADR 2026-10.5sk9's P4c
/// amendment), and ``RatchetSessions/Sealing/unavailable`` where the engine has no base.
@Suite struct RatchetSessionsSealTests {
    static let start: Int64 = 100_000_000
    static let lowOrderPoint = [UInt8](repeating: 0, count: RatchetCrypto.keyByteCount)

    /// The peer's own signature over 32 zero bytes: it verifies, and X25519 refuses the point.
    private func lowOrder(of side: RatchetSessionSide) throws -> PeerPrekey {
        let signature = try side.identity.signature(for: RatchetCrypto.spkSigningBytes(id: 1, pub: Self.lowOrderPoint))
        return try #require(
            PeerPrekey(verifying: PrekeyInfo(id: 1, pub: Self.lowOrderPoint, sig: signature), signedBy: side.identity.bundle))
    }

    private typealias SealAnswer = RatchetSessions.Answer<RatchetSessions.Sealing>

    private func sealing(_ side: RatchetSessionSide, to bundle: PublicKeyBundle? = nil, _ prekey: PeerPrekey?, now: Int64) -> SealAnswer {
        side.sessions.sealDm(
            to: bundle ?? side.peer.identity.bundle,
            prekey: prekey,
            plaintext: Array("x".utf8),
            aad: RatchetSessionSide.aad,
            now: now
        )
    }

    private func isSettled(_ answer: RatchetSessions.Answer<RatchetSessions.Sealing>, _ expected: RatchetSessions.Sealing) -> Bool {
        guard case .settled(let sealing) = answer else {
            return false
        }
        return sealing == expected
    }

    @Test func aSealToALowOrderPrekeyIsNullAndPersistsNothing() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let refused = try lowOrder(of: bob)
        #expect(isSettled(sealing(alice, refused, now: Self.start), .refusedKey))
        #expect(alice.store.records(of: bob.nodeId) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
        // And the next try is the same answer, not a half-written session.
        #expect(isSettled(sealing(alice, refused, now: Self.start + 1), .refusedKey))
        #expect(alice.store.session(bob.nodeId) == nil)
    }

    @Test func aSealToALowOrderIdentityKeyIsNull() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let forged = try #require(PublicKeyBundle(signingKey: bob.identity.bundle.signingKey, agreementKey: Self.lowOrderPoint))
        #expect(isSettled(sealing(alice, to: forged, try alice.prekey(), now: Self.start), .refusedKey))
        #expect(alice.store.session(forged.nodeId) == nil)
    }

    @Test func aResetToALowOrderPrekeyIsNoPrekey() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let answer = alice.sessions.sealResetDm(
            to: bob.identity.bundle,
            prekey: try lowOrder(of: bob),
            plaintext: RatchetSessionSide.resetBody,
            aad: RatchetSessionSide.aad,
            now: Self.start
        )
        guard case .settled(.refusedKey) = answer else {
            Issue.record("expected the reset refused as having no usable prekey, got \(answer)")
            return
        }
        #expect(alice.store.session(bob.nodeId) == nil)
    }

    /// A legacy unconfirmed row (no base recorded) whose epoch boundary would need the low-order key: refused, not thrown.
    @Test func aLegacyRowsEpochOverALowOrderBaseIsRefusedNotThrown() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        _ = try alice.seal("hello", now: Self.start)
        var legacy = try #require(alice.store.session(bob.nodeId))
        legacy.peerBasePub = nil
        alice.store.upsertSession(legacy)
        let later = Self.start + RatchetEngine.maxEpochAgeMilliseconds + 1
        #expect(isSettled(sealing(alice, try lowOrder(of: bob), now: later), .refusedKey))
        #expect(alice.store.session(bob.nodeId)?.sendEpoch == 1)
    }

    /// #174 through the facade: Alice's next epoch after Bob's rotation reaches her opens at Bob.
    @Test func anUnconfirmedSessionsNextEpochOpensAfterThePeerRotatedItsPrekey() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let first = try alice.seal("first", now: Self.start)
        bob.prekeys[2] = try SignedPrekey.mint(id: 2, signedBy: bob.identity, createdAt: Self.start)
        let later = Self.start + RatchetEngine.maxEpochAgeMilliseconds + 1
        let next = try alice.seal("a day later", now: later, pkid: 2)
        let header = try #require(next.ratchet)
        #expect(header.se == 2)
        #expect(header.initial?.pkid == 1)
        #expect(plaintext(try bob.open(next, now: later + 1)) == Array("a day later".utf8))
        #expect(plaintext(try bob.open(first, now: later + 2)) == Array("first".utf8))
    }

    /// A row an older build initiated holds no base: it keeps sealing its current epoch toward the rotated prekey, and at
    /// the boundary seals nothing (the caller's v1) rather than a frame Bob cannot open.
    @Test func aLegacyRowSealsInEpochThenReturnsNullAtTheBoundary() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        _ = try alice.seal("first", now: Self.start)
        var legacy = try #require(alice.store.session(bob.nodeId))
        legacy.peerBasePub = nil
        alice.store.upsertSession(legacy)
        bob.prekeys[2] = try SignedPrekey.mint(id: 2, signedBy: bob.identity, createdAt: Self.start)

        let inEpoch = try alice.seal("still epoch 1", now: Self.start + 1, pkid: 2)
        #expect(plaintext(try bob.open(inEpoch, now: Self.start + 2)) == Array("still epoch 1".utf8))
        let later = Self.start + RatchetEngine.maxEpochAgeMilliseconds + 1
        #expect(isSettled(sealing(alice, try alice.prekey(2), now: later), .unavailable))
        // The prekey the init names still serves the legacy row.
        #expect(plaintext(try bob.open(alice.seal("named", now: later, pkid: 1), now: later + 1)) == Array("named".utf8))
    }
}
