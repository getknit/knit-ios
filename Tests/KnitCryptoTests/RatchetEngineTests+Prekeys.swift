import KnitWire
import Testing

@testable import KnitCrypto

/// The prekey an unconfirmed session's epochs are based on (#174) and a key X25519 refuses (#172): knit-next's
/// `RatchetEngineTest` additions of `458c2eee`, each under its Kotlin name (`RatchetEngineTest.kt:718-821` at `4f3cd995`).
extension RatchetEngineTests {
    // MARK: #174: every pe = 0 epoch is based on the prekey its init names

    /// Alice's session stays unconfirmed past a day while Bob rotates his prekey and his profile reaches her. Her next
    /// epoch used to be based on the prekey she was handed then, Bob's newest, under an init that still names the old one,
    /// the key Bob resolves by `init.pkid`, so it failed as `AEAD_FAIL` for good.
    @Test func anUnconfirmedSessionsNextEpochAfterAPrekeyRotationIsBasedOnTheInitsPrekey() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        let first = try alice.seal("first", now: Self.now)
        let pinned = try #require(alice.session)
        #expect(pinned.peerBasePub == bob.prekey.publicKey, "initiate records the init's prekey as the base")
        #expect(pinned.peerBaseEpoch == 0)

        try bob.rotatePrekey()
        #expect(alice.peerPrekey.id == 2, "Alice is handed Bob's newest")
        let dayLater = Self.now + RatchetEngine.maxEpochAgeMilliseconds + 1
        let later = try alice.seal("a day later", now: dayLater)
        #expect(later.header.se == 2, "a new epoch")
        #expect(later.header.pe == 0)
        #expect(later.header.initial?.pkid == 1)

        #expect(try text(bob.open(later, now: dayLater + 1)) == "a day later")
        #expect(try text(bob.open(first, now: dayLater + 2)) == "first")
    }

    /// The same, across the 200-frame boundary instead of the day.
    @Test func anUnconfirmedSessionsEpochPastTheMessageCapAfterAPrekeyRotationStillOpens() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        for index in 0..<RatchetEngine.maxEpochMessages {
            _ = try alice.seal("m\(index)", now: Self.now)
        }
        try bob.rotatePrekey()
        let next = try alice.seal("the 201st", now: Self.now + 1)
        #expect(next.header.se == 2)
        #expect(try text(bob.open(next, now: Self.now + 2)) == "the 201st")
    }

    /// Once Bob answers, his epoch replaces the prekey as Alice's base, as before #174.
    @Test func thePeersFirstEpochReplacesTheInitsPrekeyAsTheBase() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("hello", now: Self.now), now: Self.now)
        let reply = try bob.seal("hi", now: Self.now + 1)
        _ = try alice.open(reply, now: Self.now + 1)
        let session = try #require(alice.session)
        #expect(session.confirmed)
        #expect(session.peerBaseEpoch == reply.header.se)
        #expect(session.peerBasePub == reply.header.ek)
    }

    /// A row an older build initiated holds no base. ``RatchetEngine/prekeyBase(_:peerPrekey:)`` hands its seal the peer's
    /// prekey only while it is the one the init names; after a rotation the epoch boundary answers `nil` (the caller's v1)
    /// instead of a frame the peer cannot open, and the current epoch keeps sealing.
    @Test func aLegacyUnconfirmedRowSealsInEpochAndRefusesTheBoundaryAfterARotation() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        alice.session?.peerBasePub = nil
        let oldPrekey = alice.peerPrekey
        #expect(RatchetEngine.prekeyBase(try #require(alice.session), peerPrekey: oldPrekey) == oldPrekey)

        try bob.rotatePrekey()
        let newPrekey = alice.peerPrekey
        let session = try #require(alice.session)
        #expect(RatchetEngine.prekeyBase(session, peerPrekey: newPrekey) == nil)
        #expect(RatchetEngine.prekeyBase(session, peerPrekey: nil) == nil)

        let base = RatchetEngine.prekeyBase(session, peerPrekey: newPrekey)
        let sealing = try alice.engine.seal(
            session, plaintext: Array("in epoch".utf8), aad: RatchetSide.aad, peerPrekey: base, now: Self.now + 1)
        let inEpoch = try #require(sealing)
        alice.session = inEpoch.session
        let frame = RatchetFrame(header: inEpoch.header, nonce: inEpoch.nonce, ct: inEpoch.ct)
        #expect(try text(bob.open(frame, now: Self.now + 2)) == "in epoch")

        let past = Self.now + RatchetEngine.maxEpochAgeMilliseconds + 1
        let later = RatchetEngine.prekeyBase(inEpoch.session, peerPrekey: newPrekey)
        let boundary = try alice.engine.seal(
            inEpoch.session, plaintext: Array("x".utf8), aad: RatchetSide.aad, peerPrekey: later, now: past)
        #expect(boundary == nil)
    }

    /// A confirmed session or a responder never reads the prekey: its base is the peer's epoch.
    @Test func prekeyBaseIgnoresTheInitPkidOnceTheSessionIsConfirmed() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("hello", now: Self.now), now: Self.now)
        let other = PeerPrekey(
            verifying: try SignedPrekey.mint(id: 9, signedBy: alice.identity, createdAt: 0).info, signedBy: alice.identity.bundle)
        let foreign = try #require(other)
        #expect(RatchetEngine.prekeyBase(try #require(bob.session), peerPrekey: foreign) == foreign)
    }

    // MARK: #172: a key X25519 refuses throws out of the engine; the session layer maps it to "cannot seal"

    @Test func aLowOrderPrekeyThrowsOutOfInitiateAndAFreshEpoch() throws {
        let (alice, bob) = try RatchetSide.pair()
        let signature = try bob.identity.signature(for: RatchetCrypto.spkSigningBytes(id: 1, pub: Self.lowOrderPoint))
        let lowOrder = try #require(
            PeerPrekey(verifying: PrekeyInfo(id: 1, pub: Self.lowOrderPoint, sig: signature), signedBy: bob.identity.bundle),
            "the signature verifies: a peer signs what it likes")
        #expect(throws: RatchetCryptoError.lowOrderPoint) {
            try alice.engine.initiate(
                peerId: bob.nodeId, identity: alice.identity, peerIdentity: bob.identity.bundle, peerPrekey: lowOrder, now: Self.now)
        }
        try alice.initiate(now: Self.now)
        var legacy = try #require(alice.session)
        legacy.peerBasePub = nil
        #expect(throws: RatchetCryptoError.lowOrderPoint) {
            try alice.engine.seal(
                legacy, plaintext: Array("x".utf8), aad: RatchetSide.aad, peerPrekey: lowOrder, now: Self.now, forceNewEpoch: true)
        }
    }
}
