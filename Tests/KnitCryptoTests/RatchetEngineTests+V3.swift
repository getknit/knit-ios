import KnitWire
import Testing

@testable import KnitCrypto

/// Crypto scheme v3 (knit-next ADR 059): a derived nonce and a header bound into the AAD, on v2's unchanged chain.
extension RatchetEngineTests {
    @Test func aV3FrameCarriesNoNonceAndOpensOnEveryRungOfTheLadder() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)

        // A fresh epoch derivation (the init frame), then the live chain.
        let first = try alice.seal("v3 init", now: Self.now, v3: true)
        #expect(first.nonce == nil, "v3 derives its nonce; nothing random rides the wire")
        #expect(try text(bob.open(first, now: Self.now)) == "v3 init")
        #expect(try text(bob.open(alice.seal("v3 live", now: Self.now, v3: true), now: Self.now)) == "v3 live")

        // Out of order: the skipped index opens later from its stored message key alone, which is why the nonce derives
        // from the message key and not the chain key.
        let skipped = try alice.seal("v3 skipped", now: Self.now, v3: true)
        let later = try alice.seal("v3 later", now: Self.now, v3: true)
        #expect(try text(bob.open(later, now: Self.now)) == "v3 later")
        #expect(try text(bob.open(skipped, now: Self.now)) == "v3 skipped")

        // A forced new epoch, and v2 and v3 interleaved on one session.
        #expect(try text(bob.open(alice.seal("v3 new epoch", now: Self.now, force: true, v3: true), now: Self.now)) == "v3 new epoch")
        #expect(try text(bob.open(alice.seal("v2 after v3", now: Self.now), now: Self.now)) == "v2 after v3")
        #expect(try text(bob.open(alice.seal("v3 after v2", now: Self.now, v3: true), now: Self.now)) == "v3 after v2")
    }

    @Test func aV3FrameOpenedAsV2OrAV2FrameOpenedAsV3IsAeadFail() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        let v3 = try alice.seal("hello", now: Self.now, v3: true)
        // Handed a nonce, the receiver binds no header and uses the carried nonce: the wrong AAD and IV.
        let asV2 = RatchetFrame(header: v3.header, nonce: [UInt8](repeating: 0, count: RatchetCrypto.nonceByteCount), ct: v3.ct)
        #expect(try bob.open(asV2, now: Self.now).failure == .aeadFail)
        let v2 = try alice.seal("hello again", now: Self.now)
        // A v2 frame with its nonce stripped: the receiver derives one and binds the header, again the wrong pair.
        #expect(try bob.open(RatchetFrame(header: v2.header, nonce: nil, ct: v2.ct), now: Self.now).failure == .aeadFail)
    }

    @Test func aV3FrameBindsItsHeaderFlagsAndInitClock() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        let frame = try alice.seal("hello", now: Self.now, v3: true)
        let header = frame.header
        let initial = try #require(header.initial)

        // The two header fields the derived key does not already bind, a flipped reset flag and a moved establishment
        // clock, must fail the AEAD rather than reach the session machinery.
        var flagged = header
        flagged.flags = RatchetHeader.resetFlag
        #expect(try bob.open(RatchetFrame(header: flagged, nonce: nil, ct: frame.ct), now: Self.now).failure == .aeadFail)
        var movedClock = header
        movedClock.initial = RatchetInit(eph: initial.eph, pkid: initial.pkid, at: initial.at + 1)
        #expect(try bob.open(RatchetFrame(header: movedClock, nonce: nil, ct: frame.ct), now: Self.now).failure == .aeadFail)
        // The untouched frame still opens after the two refusals: nothing was committed.
        #expect(try text(bob.open(frame, now: Self.now)) == "hello")
    }
}
