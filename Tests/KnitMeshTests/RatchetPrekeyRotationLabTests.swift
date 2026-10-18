import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// #174 on two engines of this port with the switch on: knit-next's `SessionLabTest` cases of `458c2eee`, under their
/// Kotlin names (`SessionLabTest.kt` at `4f3cd995`). The initiator's session stays unconfirmed past a day, since the
/// responder's answers never reach it, while the responder's prekey rotation lands and its profile does reach the
/// initiator. The initiator's next DM opens a new epoch, which used to be based on the newest pinned prekey under an init
/// naming the old one; the responder resolves the base by `init.pkid`, so every such frame failed as `AEAD_FAIL`. Now it
/// is based on the prekey its init names, and opens.
///
/// The rotation is driven by hand, as Kotlin's is, rather than by a seven-day jump whose sweeps would judge everything by
/// a calendar this scenario does not need: the ring mints the next prekey, and an edit carries it in the profile.
@Suite struct RatchetPrekeyRotationLabTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private static let day: Int64 = 86_400_000

    private func anUnconfirmedSessionOutlivesThePeersPrekeyRotation(initiatorHasTheSmallerId: Bool) throws {
        let lab = EngineLab([try EngineFixture.ratcheting(alice, seed: 11), try EngineFixture.ratcheting(bob, seed: 12)])
        lab.link(0, 1)
        let smaller = alice.nodeId < bob.nodeId ? 0 : 1
        let initiator = initiatorHasTheSmallerId ? smaller : 1 - smaller
        let responder = 1 - initiator
        let toward = lab[responder].me.nodeId
        let firstPrekey = try #require(lab[initiator].stores.peers.peer(toward)?.prekey?.id)

        // The responder's answers never reach the initiator.
        lab.hold(from: responder, to: initiator)
        let before = try #require(lab[initiator].engine.sendDirectMessage("before the rotation", to: toward)).id
        lab.carry()
        #expect(lab.thread(responder, with: initiator).contains { $0.hasPrefix(before) })

        // A day on, past the epoch's age, the responder's rotation lands, and an edit floods the profile that carries it.
        lab.advance(Self.day + 60_000)
        let rotating = lab[responder].engine
        var ring = try #require(rotating.prekeyRing)
        _ = try ring.rotate(now: lab[responder].clock.wallMilliseconds())
        rotating.prekeyRing = ring
        rotating.updateProfile(name: "Rotated", status: "rotated", openToChat: true)
        rotating.syncPrekey(atStart: false)
        lab.release(from: responder, to: initiator) { held in
            held.filter { item in
                guard case .frame(let written) = item else {
                    return false
                }
                return written.envelope.type == .profile
            }
        }
        lab.hold(from: responder, to: initiator)
        let pinned = try #require(lab[initiator].stores.peers.peer(toward)?.prekey?.id)
        #expect(pinned > firstPrekey, "the initiator pinned the rotated prekey")
        #expect(lab[initiator].ratchetRecords(of: lab[responder].me).session?.confirmed == false, "still unconfirmed")

        let after = try #require(lab[initiator].engine.sendDirectMessage("after the rotation", to: toward)).id
        lab.carry()
        let sealedAfter = try #require(lab.chats(from: initiator, to: responder, id: after).first)
        let header = try #require(try ChatContent(decoding: sealedAfter.envelope.payload).enc?.ratchet)
        #expect(header.se == 2 && header.pe == 0 && header.initial?.pkid == firstPrekey, "a new epoch under the init's prekey")
        #expect(lab.thread(responder, with: initiator).contains { $0.hasPrefix(after) }, "the responder reads it")
        #expect(lab[responder].engine.dropped[.ratchetAeadFail] == nil && lab[responder].engine.dropped[.ratchetEpochGone] == nil)

        // The hold lifts as a field link's loss does: the link drops and comes back, and an answer confirms the initiator.
        lab.unlink(0, 1)
        lab.link(0, 1)
        _ = try #require(lab[responder].engine.sendDirectMessage("back", to: lab[initiator].me.nodeId))
        lab.carry()
        lab.expectConverged(initiator, responder, atLeast: 3, "after the rotation")
    }

    @Test func theSmallerIdsUnconfirmedSessionOutlivesThePeersPrekeyRotation() throws {
        try anUnconfirmedSessionOutlivesThePeersPrekeyRotation(initiatorHasTheSmallerId: true)
    }

    @Test func theLargerIdsUnconfirmedSessionOutlivesThePeersPrekeyRotation() throws {
        try anUnconfirmedSessionOutlivesThePeersPrekeyRotation(initiatorHasTheSmallerId: false)
    }
}
