import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// When each peer was last heard, between two engines on one link (knit-next ADR 2026-10.k8ge): Bob's own signed post
/// stamps Alice's row for him on her next bank, a re-serve or a forgery never lowers or moves it, and nothing either side
/// carries or cues moves with the stamps.
@Suite struct MeshEngineHeardFromPairTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private static let hour: Int64 = 3_600_000
    private static let bank: Int64 = 60_000

    /// What one run of the scenario leaves.
    private struct Outcome {
        var aliceLive: Set<String>
        var bobLive: Set<String>
        var aliceCue: UInt32
        var bobCue: UInt32
    }

    /// Hands `to` every frame `from` wrote to it, or flooded, as the link between them would.
    private func carry(from: EngineFixture, to: EngineFixture) {
        let written = from.transport.written.filter { $0.to == nil || $0.to == to.me.nodeId }
        from.transport.clear()
        for frame in written {
            to.engine.receive(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: from.me.nodeId))
        }
    }

    private func carryBoth(_ first: EngineFixture, _ second: EngineFixture) {
        for _ in 0..<4 {
            carry(from: first, to: second)
            carry(from: second, to: first)
        }
    }

    private func advance(_ fixtures: EngineFixture..., by milliseconds: Int64) {
        for fixture in fixtures {
            fixture.advance(milliseconds)
        }
    }

    private func peersHeard(_ fixture: EngineFixture) -> [MeshEvent] {
        fixture.engine.drainEvents().filter { if case .peersHeard = $0 { true } else { false } }
    }

    /// Hands `fixture` a copy of a post of Bob's whose signature does not verify, stamped now, and a signed one of his stamped
    /// at the bottom of the range.
    private func sendForgedAndAncient(to fixture: EngineFixture) throws {
        var forged = try bob.roomPost("forged", id: frameIdOf("forged"), sentAt: fixture.clock.wallMilliseconds())
        forged.wire.sig[0] ^= 1
        let ancient = try bob.roomPost("ancient", id: frameIdOf("ancient"), sentAt: .min)
        for frame in [forged, ancient] {
            fixture.engine.receive(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: bob.nodeId))
        }
    }

    /// The scenario, banking every `bank` ms; `checks` says whether to assert the stamps along the way.
    private func run(bank: Int64, checks: Bool) throws -> Outcome {
        let configuration = MeshConfiguration(seenBankMilliseconds: bank)
        let alices = EngineFixture(alice, configuration: configuration, seed: 11)
        let bobs = EngineFixture(bob, configuration: configuration, seed: 22)
        alices.link(bob)
        bobs.link(alice)
        carryBoth(alices, bobs)
        let pinnedAt = try #require(alices.stores.peers.peer(bob.nodeId)?.lastSeenAt, "the link-up pushed Bob's profile")
        advance(alices, bobs, by: 7 * Self.hour)
        carryBoth(alices, bobs)
        _ = alices.engine.drainEvents()

        // Bob's own signed post, and a copy of it forged under a new id, and a frame of his at the bottom of the range.
        let post = try #require(bobs.engine.postToRoom("hello"))
        carry(from: bobs, to: alices)
        // Half the bank's interval on, so a forged stamp that got through would read later than the post.
        advance(alices, bobs, by: Self.bank / 2)
        try sendForgedAndAncient(to: alices)
        advance(alices, bobs, by: Self.bank / 2)
        carryBoth(alices, bobs)
        if checks {
            #expect(alices.stores.peers.peer(bob.nodeId)?.lastSeenAt == post.sentAt, "Bob's own sentAt, from his post")
            #expect(peersHeard(alices) == [.peersHeard([bob.nodeId])], "one event for the bank")
        }

        // Past the router's memory, an older frame of Bob's comes round again: his profile from before.
        advance(alices, bobs, by: SeenSet.defaultWindowMilliseconds + 1)
        carryBoth(alices, bobs)
        let profile = try #require(alices.stores.peers.profileFrame(of: bob.nodeId))
        let decoded = try RelayEnvelope(decoding: profile.signed)
        let admitted = alices.engine.routerCounters.admitted
        alices.engine.receive(
            InboundFrame(wire: WireEnvelope(sig: profile.sig, signed: profile.signed), envelope: decoded, from: bob.nodeId))
        if checks {
            #expect(alices.engine.routerCounters.admitted == admitted + 1, "the re-serve reached the door as a first sight")
        }
        // And a second post inside the gate.
        bobs.engine.postToRoom("again")
        carry(from: bobs, to: alices)
        _ = alices.engine.drainEvents()
        advance(alices, bobs, by: Self.bank)
        carryBoth(alices, bobs)
        if checks {
            #expect(decoded.sentAt < post.sentAt && decoded.sentAt <= pinnedAt)
            #expect(alices.stores.peers.peer(bob.nodeId)?.lastSeenAt == post.sentAt, "never lowered, and the gate held")
            #expect(peersHeard(alices).isEmpty, "a bank inside the gate writes nothing and says nothing")
        }
        let now = alices.clock.wallMilliseconds()
        return Outcome(
            aliceLive: Set(alices.stores.custody.liveIds(now: now)),
            bobLive: Set(bobs.stores.custody.liveIds(now: now)),
            aliceCue: alices.engine.digestCue,
            bobCue: bobs.engine.digestCue
        )
    }

    @Test func bobsSignedPostStampsAlicesRowAndNothingElseMoves() throws {
        let stamped = try run(bank: Self.bank, checks: true)
        // The same run with a bank that never comes due: what each side carries and cues is the same.
        let unstamped = try run(bank: 365 * 24 * Self.hour, checks: false)
        #expect(stamped.aliceLive == unstamped.aliceLive && stamped.bobLive == unstamped.bobLive)
        #expect(stamped.aliceCue == unstamped.aliceCue && stamped.bobCue == unstamped.bobCue)
        #expect(!stamped.aliceLive.isEmpty)
    }
}
