import KnitWire
import Testing

@testable import KnitCrypto

/// The typed failures, and the damping on a peer's epoch jumps.
extension RatchetEngineTests {
    // MARK: Typed failures

    @Test func aFrameWithoutInitToAFreshDeviceIsNoSession() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("establish", now: Self.now), now: Self.now)
        let confirmed = try bob.seal("no init attached", now: Self.now)

        let stranger = try RatchetSide(.repeating("c"))
        stranger.hold(bob)
        #expect(try stranger.open(confirmed, now: Self.now).failure == .noSession)
    }

    @Test func anInitAgainstAPrunedPrekeyIsEpochGone() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        bob.prekeyResolvable = false
        #expect(try bob.open(alice.seal("hello", now: Self.now), now: Self.now).failure == .epochGone)
    }

    @Test func aFrameAgainstADeletedOwnEpochIsEpochGone() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("hello", now: Self.now), now: Self.now)
        let reply = try bob.seal("reply", now: Self.now)

        alice.rows.localEpochs = [:]
        #expect(try alice.open(reply, now: Self.now).failure == .epochGone)
    }

    @Test func structurallyInvalidHeadersAreBadHeader() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        let frame = try alice.seal("hello", now: Self.now)

        // The header is rebuilt around the real nonce and ciphertext: only the header is under test, and each of these
        // is refused before the session machinery sees it.
        #expect(try tamper(frame, at: bob, dropInit: true) == .badHeader)
        #expect(try tamper(frame, at: bob, n: RatchetEngine.maxEpochMessages) == .badHeader)
        #expect(try tamper(frame, at: bob, n: -1) == .badHeader)
        #expect(try tamper(frame, at: bob, se: 0) == .badHeader)
        #expect(try tamper(frame, at: bob, ek: Array(frame.header.ek.prefix(31))) == .badHeader)

        // A negative pe used to slip through on the strength of the attached init and land as EPOCH_GONE, which counts
        // toward a reset. Structurally invalid must mean BAD_HEADER.
        #expect(try tamper(frame, at: bob, pe: -1) == .badHeader)

        // Both epoch numbers are bounded above too, or an absurd one reaches the same wrong report.
        #expect(try tamper(frame, at: bob, se: RatchetEngine.maxEpochNumber + 1) == .badHeader)
        #expect(try tamper(frame, at: bob, pe: RatchetEngine.maxEpochNumber + 1) == .badHeader)
    }

    @Test func aTamperedCiphertextIsAeadFail() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        let frame = try alice.seal("hello", now: Self.now)
        var ct = frame.ct
        ct[0] &+= 1
        #expect(try bob.open(RatchetFrame(header: frame.header, nonce: frame.nonce, ct: ct), now: Self.now).failure == .aeadFail)
    }

    /// `frame` opened by `receiver` with its header rebuilt around the real nonce and ciphertext.
    private func tamper(
        _ frame: RatchetFrame,
        at receiver: RatchetSide,
        se: Int = 1,
        ek: [UInt8]? = nil,
        pe: Int = 0,
        n: Int = 0,
        dropInit: Bool = false
    ) throws -> RatchetEngine.OpenOutcome.Failed? {
        let header = RatchetHeader(se: se, ek: ek ?? frame.header.ek, pe: pe, n: n, initial: dropInit ? nil : frame.header.initial)
        return try receiver.open(RatchetFrame(header: header, nonce: frame.nonce, ct: frame.ct), now: Self.now).failure
    }

    // MARK: Damping a peer's epoch jumps

    /// A peer that jumps its own numbering must not pin our DH base. The frame still opens (refusing the adoption is no
    /// drop), but `peerBaseEpoch` stays put, so the turnaround rule keeps firing for the rest of the session.
    @Test func anAbsurdEpochJumpIsNotAdoptedAsOurDhBase() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("hello", now: Self.now), now: Self.now)
        _ = try bob.open(alice.seal("again", now: Self.now), now: Self.now)
        let anchor = try #require(bob.session).peerBaseEpoch
        #expect(anchor == 1)

        // alice's numbering pushed far past anything she could reach; the frame is sealed for real, so it opens, and only
        // the adoption is in question.
        alice.session?.sendEpoch = anchor + RatchetEngine.maxEpochJump
        let jumped = try alice.seal("still readable", now: Self.now, force: true)
        #expect(jumped.header.se == anchor + RatchetEngine.maxEpochJump + 1)
        #expect(try text(bob.open(jumped, now: Self.now)) == "still readable")
        #expect(try #require(bob.session).peerBaseEpoch == anchor, "the out-of-range epoch is not adopted as our base")

        // The session is undamaged: alice's next in-range epoch is still adopted, so healing survives.
        alice.session?.sendEpoch = anchor
        let inRange = try alice.seal("in range", now: Self.now, force: true)
        #expect(inRange.header.se == anchor + 1)
        #expect(try text(bob.open(inRange, now: Self.now)) == "in range")
        #expect(try #require(bob.session).peerBaseEpoch == anchor + 1)
    }

    /// The jump bound is inclusive.
    @Test func anEpochExactlyAtTheJumpBoundIsAdopted() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("hello", now: Self.now), now: Self.now)
        let anchor = try #require(bob.session).peerBaseEpoch

        alice.session?.sendEpoch = anchor + RatchetEngine.maxEpochJump - 1
        let atBound = try alice.seal("edge", now: Self.now, force: true)
        #expect(atBound.header.se == anchor + RatchetEngine.maxEpochJump)
        #expect(try text(bob.open(atBound, now: Self.now)) == "edge")
        #expect(try #require(bob.session).peerBaseEpoch == anchor + RatchetEngine.maxEpochJump)
    }

    /// With no anchor yet the jump bound must not apply: after a replacement our anchor is 0 while the peer's numbering
    /// keeps climbing, so a relative bound would refuse its very next frame, and BAD_HEADER drives no reset, so the pair
    /// would stay dark with no way back.
    @Test func anUnanchoredSessionAdoptsAnyLegalEpoch() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        alice.session?.sendEpoch = 5 * RatchetEngine.maxEpochJump
        let farAhead = try alice.seal("after a reset", now: Self.now, force: true)
        #expect(farAhead.header.se == 5 * RatchetEngine.maxEpochJump + 1)
        #expect(try text(bob.open(farAhead, now: Self.now)) == "after a reset")
        #expect(try #require(bob.session).peerBaseEpoch == farAhead.header.se)
    }
}
