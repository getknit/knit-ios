import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// knit-next ADR 2026-10.j67x's rules 2 and 3 on two real facades (ADR 2026-10.5sk9's P9a amendment): the replaced era's
/// own init that predates our reset is read, not raced, and a second re-root over our own unanswered reset keeps the drained
/// root in the slot. They mirror knit-next's `RatchetSessionsExportTest.theReplacedErasOwnInitReServedWhileOurResetWaitsIsNoRace`,
/// `theReplacedErasInitSealedSinceOurResetStillRaces…` and `aSecondResetOverOurUnansweredOne…` at `f018bc8ce`, less the spool
/// scopes (rule 1, deferred). Each runs in both node-id orders; every envelope is opened with the stamp it was sealed at.
extension RatchetSessionsResetTests {
    static let skew = WireProtocol.maxFutureSkewMilliseconds

    /// Two sides, `us` and the peer, the peer the smaller id when `peerIsSmaller`.
    private func sides(peerIsSmaller: Bool) throws -> (us: RatchetSessionSide, peer: RatchetSessionSide) {
        let (one, two) = try RatchetSessionSide.pair()
        return (one.nodeId < two.nodeId) == peerIsSmaller ? (two, one) : (one, two)
    }

    /// Rule 2, with its boundary: the peer started the root we hold and confirmed it on our answer; we reset `resetAfter`
    /// past the peer's seal, and the peer adopted the reset. A frame it sealed then as that root's unconfirmed initiator, its
    /// init attached, comes back from custody. More than the skew before our reset, it is read under the drained root and
    /// moves nothing, whatever the identity's item keeps (the init's ephemeral, here, as our anchor on it put it there: it
    /// is never answered-before, since it derives our draining `prevRoot`). At exactly the skew it races, as Kotlin's strict
    /// `<` has it. Raced, a smaller-id peer's frame put us back on the root it left; a larger-id peer's restarted the drain and
    /// anchored its init.
    @Test(arguments: [true, false], [skew + 1, skew])
    func theReplacedErasOwnInitThatPredatesOurResetIsReadNotRaced(peerIsSmaller: Bool, resetAfter: Int64) throws {
        let (us, peer) = try sides(peerIsSmaller: peerIsSmaller)
        let reServed = try peer.seal("sealed as that root's initiator", now: Self.t0)
        #expect(plaintext(try us.open(peer.seal("first", now: Self.t0), now: Self.t0, sentAt: Self.t0)) != nil)
        #expect(plaintext(try peer.open(us.seal("answer", now: Self.t0 + 1), now: Self.t0 + 1, sentAt: Self.t0 + 1)) != nil)
        let resetAt = Self.t0 + resetAfter
        let reset = try sealedReset(us.reset(now: resetAt))
        #expect(plaintext(try peer.open(reset.envelope, now: resetAt + 1, sentAt: resetAt)) != nil, "the peer adopted our reset")
        let before = try #require(us.session)
        let adopted = try #require(peer.session).root
        #expect(before.root == adopted && !before.confirmed && before.peerInitEphPub == nil)

        let read = try us.open(reServed, now: resetAt + 2, sentAt: Self.t0) { _ in true }
        #expect(plaintext(read) != nil, "opened as a first verdict, never as an init answered before a reinstall")
        guard resetAfter > Self.skew else {
            #expect(us.session != before, "at exactly the skew the frame races")
            return
        }
        #expect(us.session == before, "no race, no remnant, no purge: the drain and the anchor untouched")
        #expect(us.session?.root == adopted, "still on the root the peer adopted")
        #expect(plaintext(try us.open(peer.seal("after", now: resetAt + 3), now: resetAt + 3, sentAt: resetAt + 3)) != nil)
        let met = try #require(us.session)
        #expect(met.confirmed && met.root == peer.session?.root && met.weAreInitiator, "the pair meets on our reset")
    }

    /// Rule 2's gate: the peer never heard our answer, so it is still the replaced root's unconfirmed initiator, and a frame
    /// it sealed since our reset races as before. The pair meets on one root, the smaller id's.
    @Test(arguments: [true, false])
    func theReplacedErasInitSealedSinceOurResetStillRacesAndThePairMeetsOnOneRoot(peerIsSmaller: Bool) throws {
        let (us, peer) = try sides(peerIsSmaller: peerIsSmaller)
        #expect(plaintext(try us.open(peer.seal("first", now: Self.t0), now: Self.t0, sentAt: Self.t0)) != nil)
        let replaced = try #require(us.session).root
        let resetAt = Self.t1
        let reset = try sealedReset(us.reset(now: resetAt))
        let ours = try #require(us.session).root
        let since = try peer.seal("still unconfirmed", now: resetAt + 1000)
        #expect(since.ratchet?.initial != nil, "precondition: the peer still rides its init")
        #expect(plaintext(try us.open(since, now: resetAt + 1000, sentAt: resetAt + 1000)) != nil)
        #expect(plaintext(try peer.open(reset.envelope, now: resetAt + 2000, sentAt: resetAt)) != nil)
        #expect(plaintext(try peer.open(us.seal("turn", now: resetAt + 3000), now: resetAt + 3000, sentAt: resetAt + 3000)) != nil)
        #expect(plaintext(try us.open(peer.seal("around", now: resetAt + 4000), now: resetAt + 4000, sentAt: resetAt + 4000)) != nil)
        let (mine, theirs) = (try #require(us.session), try #require(peer.session))
        #expect(mine.confirmed && theirs.confirmed && mine.root == theirs.root && mine.weAreInitiator != theirs.weAreInitiator)
        #expect(mine.root == (peerIsSmaller ? replaced : ours), "the smaller id's root")
    }

    /// Two sides on one root, past three turnarounds so each one's base for the other is an epoch above 1, the number our
    /// reset mints again (knit-next ADR 027).
    private func talked(resetterIsSmaller: Bool) throws -> (us: RatchetSessionSide, peer: RatchetSessionSide) {
        let (us, peer) = try sides(peerIsSmaller: !resetterIsSmaller)
        for turn in Int64(0)..<3 {
            let at = Self.t0 + 10 * turn
            #expect(plaintext(try peer.open(us.seal("there \(turn)", now: at), now: at, sentAt: at)) != nil)
            #expect(plaintext(try us.open(peer.seal("back \(turn)", now: at + 1), now: at + 1, sentAt: at + 1)) != nil)
        }
        return (us, peer)
    }

    /// Rule 3: our first reset is lost, and the peer goes on sealing under the root it knows. A minute on, past
    /// `resetInFlight`, we reset again: the slot keeps that root, with our role under it and a fresh drain, so we go on reading
    /// the peer, and the peer adopts the second reset.
    @Test(arguments: [true, false])
    func aSecondResetOverOurUnansweredOneKeepsTheRootThePeerIsOn(resetterIsSmaller: Bool) throws {
        let (us, peer) = try talked(resetterIsSmaller: resetterIsSmaller)
        let held = try #require(us.session)
        _ = try sealedReset(us.reset(now: Self.t1))
        #expect(isDeclined(try us.reset(now: Self.t1 + Self.floor - 1)), "inside resetInFlight")
        let second = try sealedReset(us.reset(now: Self.t1 + Self.floor))
        #expect(second.reRooted)
        let slot = try #require(us.session)
        #expect(slot.prevRoot == held.root && slot.prevRootWeAreInitiator == held.weAreInitiator, "the root the peer is on")
        #expect(slot.prevRootExpiresAt == Self.t1 + Self.floor + RatchetEngine.previousRootMilliseconds)
        #expect(slot.prevRootOwnInitAt == nil)

        let after = Self.t1 + 2 * Self.floor
        let sealedOn = try peer.seal("still on the root I know", now: after)
        #expect((sealedOn.ratchet?.pe ?? 0) >= 2, "precondition: based on an epoch our resets never mint again")
        #expect(plaintext(try us.open(sealedOn, now: after, sentAt: after)) != nil, "read for the drain")
        #expect(plaintext(try peer.open(second.envelope, now: after + 1, sentAt: Self.t1 + Self.floor)) != nil)
        #expect(plaintext(try us.open(peer.seal("on your reset", now: after + 2), now: after + 2, sentAt: after + 2)) != nil)
        let (mine, theirs) = (try #require(us.session), try #require(peer.session))
        #expect(mine.confirmed && mine.root == theirs.root && mine.weAreInitiator && !theirs.weAreInitiator)
    }

    /// Rule 3's drain restarts on each such re-root: a second reset 47 hours after the first keeps the root another 48, so the
    /// peer's frame sealed past the first drain's end still opens.
    @Test(arguments: [true, false])
    func theDrainRestartsOnEachReRootOverOurUnansweredReset(resetterIsSmaller: Bool) throws {
        let (us, peer) = try talked(resetterIsSmaller: resetterIsSmaller)
        let held = try #require(us.session)
        _ = try sealedReset(us.reset(now: Self.t1))
        let hour: Int64 = 3_600_000
        let second = Self.t1 + 47 * hour
        _ = try sealedReset(us.reset(now: second))
        let slot = try #require(us.session)
        #expect(slot.prevRoot == held.root && slot.prevRootExpiresAt == second + RatchetEngine.previousRootMilliseconds)

        let pastFirstDrain = Self.t1 + 48 * hour + 60_000
        let late = try peer.seal("past the first drain", now: pastFirstDrain)
        #expect(plaintext(try us.open(late, now: pastFirstDrain, sentAt: pastFirstDrain)) != nil)
    }
}
