import KnitWire
import Testing

@testable import KnitCrypto

/// What this port adds to Kotlin's 43 cases: where Swift and Apple's crypto differ from Kotlin and Tink, where the
/// engine is stricter than Kotlin's because its caller is not yet written, and the branches Kotlin's suite leaves to its
/// session layer's tests (the replacement floor, a drain that runs out).
extension RatchetEngineTests {
    /// A point of order 1, which X25519 turns into an all-zero secret: Tink refuses it, swift-crypto and CryptoKit do not.
    static let lowOrderPoint = [UInt8](repeating: 0, count: RatchetCrypto.keyByteCount)

    // MARK: What Tink throws

    /// A carried nonce that is not 12 bytes is `BAD_HEADER`, as Kotlin's pipeline refuses it before its engine
    /// (`InboundPipeline.kt:1025-1028`); AES-GCM would only fail it, as `AEAD_FAIL`, which counts toward a reset.
    @Test func aCarriedNonceThatIsNotTwelveBytesIsBadHeader() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        let frame = try alice.seal("hello", now: Self.now)
        for nonce in [[], [UInt8](repeating: 0, count: 16)] {
            let reshaped = RatchetFrame(header: frame.header, nonce: nonce, ct: frame.ct)
            #expect(try bob.open(reshaped, now: Self.now).failure == .badHeader)
        }
        #expect(bob.session == nil)
        #expect(try text(bob.open(frame, now: Self.now)) == "hello")
    }

    /// An `ek` X25519 refuses is `BAD_HEADER` (`RatchetEngine.kt:456-460`), never `AEAD_FAIL`: swift-crypto gives zeros
    /// where Tink throws, and ``RatchetCrypto/dh(_:_:)`` refuses them.
    @Test func aLowOrderEkIsBadHeaderNeverAeadFail() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        let frame = try alice.seal("hello", now: Self.now)
        var header = frame.header
        header.ek = Self.lowOrderPoint
        #expect(try bob.open(RatchetFrame(header: header, nonce: frame.nonce, ct: frame.ct), now: Self.now).failure == .badHeader)
    }

    /// An init whose ephemeral X25519 refuses throws out of the X3DH respond, as Tink's does out of Kotlin's engine,
    /// wherever the init is answered: a first contact, a race and a replacement. Nothing changes, and it is never a typed
    /// `AEAD_FAIL`: the caller drops it without counting it toward a reset.
    @Test func anInitWhoseEphemeralX25519RefusesThrowsOutOfTheEngineAndChangesNothing() throws {
        func spoiled(_ frame: RatchetFrame, eph: [UInt8]) throws -> RatchetFrame {
            var header = frame.header
            let initial = try #require(header.initial)
            header.initial = RatchetInit(eph: eph, pkid: initial.pkid, at: initial.at)
            return RatchetFrame(header: header, nonce: frame.nonce, ct: frame.ct)
        }

        // First contact, with a low-order and a short ephemeral.
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        let first = try alice.seal("hello", now: Self.now)
        #expect(throws: RatchetCryptoError.lowOrderPoint) { try bob.open(spoiled(first, eph: Self.lowOrderPoint), now: Self.now) }
        #expect(throws: RatchetCryptoError.invalidKey) {
            try bob.open(spoiled(first, eph: Array(Self.lowOrderPoint.prefix(31))), now: Self.now)
        }
        #expect(bob.session == nil)

        // A race: bob's own unconfirmed session meets alice's init.
        try bob.initiate(now: Self.now)
        let racing = bob.session
        #expect(throws: RatchetCryptoError.lowOrderPoint) { try bob.open(spoiled(first, eph: Self.lowOrderPoint), now: Self.now) }
        #expect(bob.session == racing)

        // A replacement: bob answered alice, and her wiped device initiates again.
        bob.wipe()
        _ = try bob.open(first, now: Self.now)
        let answered = bob.session
        alice.wipe()
        try alice.initiate(now: Self.now + 10_000)
        let reborn = try alice.seal("after the wipe", now: Self.now + 10_000)
        #expect(throws: RatchetCryptoError.lowOrderPoint) { try bob.open(spoiled(reborn, eph: Self.lowOrderPoint), now: Self.now + 10_000) }
        #expect(bob.session == answered)
    }

    /// A peer prekey X25519 refuses throws out of `initiate`, as Tink's does: its signature verifies, since a hostile peer
    /// signs what it likes.
    @Test func initiatingAgainstALowOrderPrekeyThrows() throws {
        let (alice, bob) = try RatchetSide.pair()
        let signature = try bob.identity.signature(for: RatchetCrypto.spkSigningBytes(id: 1, pub: Self.lowOrderPoint))
        let prekey = try #require(
            PeerPrekey(verifying: PrekeyInfo(id: 1, pub: Self.lowOrderPoint, sig: signature), signedBy: bob.identity.bundle))
        #expect(throws: RatchetCryptoError.lowOrderPoint) {
            try alice.engine.initiate(
                peerId: bob.nodeId, identity: alice.identity, peerIdentity: bob.identity.bundle, peerPrekey: prekey, now: Self.now)
        }
    }

    // MARK: Sealing

    /// A fresh epoch with no base to DH against seals nothing, and the caller sends v1 (`RatchetEngine.kt:259-264`).
    @Test func aNewEpochWithNoBaseSealsNothing() throws {
        let (alice, bob) = try RatchetSide.pair()
        let unbased = RatchetEngine.SessionState(
            peerId: bob.nodeId,
            confirmed: true,
            weAreInitiator: false,
            root: RatchetCrypto.generateKeyPair().privateKey,
            establishedAt: Self.now
        )
        let sealed = try alice.engine.seal(unbased, plaintext: [1], aad: RatchetSide.aad, peerPrekey: nil, now: Self.now)
        #expect(sealed == nil)
    }

    /// A session missing its send key or, unconfirmed, its init seals nothing, where Kotlin's `checkNotNull` throws:
    /// nothing makes either, and the caller's answer to `nil` is a v1 DM the peer can always read.
    @Test func aSessionMissingItsSendKeyOrItsInitSealsNothing() throws {
        let (alice, _) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        var keyless = try #require(alice.session)
        keyless.sendEpochPub = nil
        var initless = try #require(alice.session)
        initless.initEphPub = nil
        for broken in [keyless, initless] {
            #expect(try alice.engine.seal(broken, plaintext: [1], aad: RatchetSide.aad, peerPrekey: alice.peerPrekey, now: Self.now) == nil)
        }
    }

    /// An IV source that does not give 12 bytes makes a v2 seal throw, before anything is committed. Java's GCM would
    /// seal under it, and every receiver would refuse the frame's nonce (`InboundPipeline.kt:1746-1747`); only a test
    /// passes such a source. A v3 seal draws no IV.
    @Test func anIvSourceOfTheWrongLengthFailsAV2SealAndNotAV3One() throws {
        let short = RatchetEngine {
            RatchetCrypto.generateKeyPair()
        } iv: {
            [UInt8](repeating: 0, count: RatchetCrypto.nonceByteCount - 1)
        }
        let (alice, bob) = try RatchetSide.pair(engine: short)
        try alice.initiate(now: Self.now)
        #expect(throws: RatchetCryptoError.sealing) { try alice.seal("v2", now: Self.now) }
        #expect(try text(bob.open(alice.seal("v3", now: Self.now, v3: true), now: Self.now)) == "v3")
    }

    // MARK: Opening

    /// Kotlin trusts its caller to list only the header's chains; this engine also checks the epoch, so a wider list
    /// never opens a frame on another epoch's chain. Epoch 1's spent cursor would otherwise read epoch 2's n 0 as a
    /// duplicate.
    @Test func aChainOfAnotherEpochNeverDecidesAFrame() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("epoch 1", now: Self.now), now: Self.now)
        let second = try alice.seal("epoch 2", now: Self.now, force: true)
        let context = RatchetEngine.OpenContext(
            selfNodeId: bob.nodeId,
            peerId: alice.nodeId,
            session: bob.session,
            recvEpochs: Array(bob.rows.chains.values),
            skippedKeys: Array(bob.rows.skippedKeys.values),
            ownBasePrivateKey: nil,
            identity: bob.identity,
            peerIdentity: alice.identity.bundle,
            prekeyForInit: bob.prekey
        )
        let outcome = try bob.engine.open(
            context, header: second.header, nonce: second.nonce, ct: second.ct, aad: RatchetSide.aad, now: Self.now)
        #expect(try text(outcome) == "epoch 2")
    }

    /// A race init naming a prekey we no longer hold cannot be answered: `EPOCH_GONE`, and our session stays as it was.
    @Test func aRaceInitNamingAPrekeyWeNoLongerHoldIsEpochGone() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        try bob.initiate(now: Self.now)
        let fromBob = try bob.seal("from bob", now: Self.now)
        let racing = alice.session
        alice.prekeyResolvable = false
        #expect(try alice.open(fromBob, now: Self.now).failure == .epochGone)
        #expect(alice.session == racing)
    }

    /// Inside the session layer's floor a replacing init is inert: the frame is read under the roots already held, here a
    /// spent index, and nothing is replaced. Past it, the same frame is adopted.
    @Test func aReplacementInsideTheFloorIsReadUnderTheRootsAlreadyHeld() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("hello", now: Self.now), now: Self.now)
        let held = try #require(bob.session)

        alice.wipe()
        try alice.initiate(now: Self.now + 10_000)
        let reborn = try alice.seal("after the wipe", now: Self.now + 10_000)
        #expect(try bob.open(reborn, now: Self.now + 10_000, allowReplacement: false).failure == .duplicate)
        #expect(bob.session == held)

        #expect(try text(bob.open(reborn, now: Self.now + 10_000)) == "after the wipe")
        #expect(try #require(bob.session).root == #require(alice.session).root)
    }

    /// A drained root opens frames until its time is up, `PREV_ROOT_TTL_MS` after the resolution that kept it, and the
    /// first open after that retires it (`retirePrevRoot`, `RatchetEngine.kt:796-804`).
    @Test func aDrainingRootStopsOpeningFramesWhenItsTimeIsUp() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        try bob.initiate(now: Self.now)
        let fromAlice = try alice.seal("from alice", now: Self.now)
        let early0 = try bob.seal("early 0", now: Self.now)
        let early1 = try bob.seal("early 1", now: Self.now)
        #expect(try text(alice.open(early0, now: Self.now)) == "early 0")
        let expiry = try #require(alice.session).prevRootExpiresAt
        #expect(expiry == Self.now + RatchetEngine.previousRootMilliseconds)

        _ = try bob.open(fromAlice, now: Self.now)
        #expect(try text(alice.open(bob.seal("answer", now: Self.now), now: expiry)) == "answer")
        #expect(try #require(alice.session).prevRoot == nil)
        #expect(try #require(alice.session).prevRootExpiresAt == 0)
        #expect(try alice.open(early1, now: expiry).failure == .aeadFail)
    }
}
