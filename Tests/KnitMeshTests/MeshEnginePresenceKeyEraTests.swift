import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A contact's presence keys across the pair's eras (ADR 2026-11.sv5t; knit-next's pz9g predicate): Android resets, its
/// next ctl 11 under the new root replaces what is held whatever its generation, and a ctl 11 it sealed under the old root
/// that arrives after the reset drains, ordered against what is held, and never starts an era.
@Suite struct MeshEnginePresenceKeyEraTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private var now: Int64 { EngineFixture.start }
    private static let minute: Int64 = 60_000

    private static func key(_ byte: UInt8) -> [UInt8] {
        [UInt8](repeating: byte, count: PresenceKey.byteCount)
    }

    /// Alice's ctl 11 handing over the key of `key.1`s at generation `key.0`, sealed at `at` against `prekey`.
    private func keyFrame(_ android: AndroidPeer, _ key: (Int64, UInt8), prekey: PeerPrekey, id: String, at: Int64) throws -> TestFrame {
        let content = PresenceKeyFrame.content([(generation: key.0, key: Self.key(key.1))])
        return try android.dm(content, to: me, prekey: prekey, id: frameIdOf(id), sentAt: at, relay: false)
    }

    private func held(_ fixture: EngineFixture) -> [HeldPresenceKey] {
        fixture.stores.presenceKeys.keys(of: alice.nodeId).map(\.held)
    }

    @Test func aResetsLowerGenerationReplacesAndTheOldRootsLateFrameNeverDoes() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        fixture.engine.accept(alice.nodeId.string)
        fixture.deliver(try keyFrame(android, (1000, 1), prekey: try fixture.ourPrekey(), id: "pk-old", at: now), from: android)
        let oldTag = try #require(held(fixture).first?.rootTag)
        // Android reads our answer to its init, so its session is confirmed and its reset re-roots rather than marks.
        let answers = fixture.answerIds
        let answer = try #require(fixture.transport.written(.chat).last { answers.contains(ExactKey($0.envelope.id)) })
        #expect(plaintext(try android.open(answer, from: me, now: now)) != nil)
        // Sealed under the old root, held back: custody re-serves frames for hours.
        let lateOlder = try keyFrame(android, (10, 3), prekey: try fixture.ourPrekey(), id: "pk-late-older", at: now + 1)
        let lateNewer = try keyFrame(android, (30, 4), prekey: try fixture.ourPrekey(), id: "pk-late-newer", at: now + 2)
        fixture.clock.advance(2 * Self.minute)
        let resetAt = now + 2 * Self.minute
        fixture.deliver(try android.resetDm(to: me, prekey: try fixture.ourPrekey(), id: frameIdOf("reset"), at: resetAt), from: android)
        fixture.deliver(try keyFrame(android, (20, 2), prekey: try fixture.ourPrekey(), id: "pk-new", at: resetAt + 1), from: android)
        let newTag = try #require(held(fixture).first?.rootTag)
        #expect(newTag != oldTag)
        #expect(held(fixture).map(\.generation) == [20], "a new era, its lower generation and all")
        #expect(fixture.engine.presenceKeyCounts.replaced == 1)
        // The old root's tail opens as a drain: lower is OLDER, higher joins the new era's keys under its tag.
        fixture.deliver(lateOlder, from: android)
        #expect(fixture.engine.dropped == [.presenceKeyRefused: 1], "opened, and refused as OLDER")
        fixture.deliver(lateNewer, from: android)
        #expect(held(fixture).map(\.generation) == [30, 20])
        #expect(held(fixture).allSatisfy { $0.rootTag == newTag }, "a drain never moves a tag")
        #expect(fixture.engine.presenceKeyCounts.replaced == 1 && fixture.engine.presenceKeyCounts.stored == 2)
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.presenceKeyListings.last?.mapValues { $0.map(\.bytes) } == [alice.nodeId: [Self.key(4), Self.key(2)]])
    }

    /// Both sides initiate, and the iPhone's smaller node id wins the race. Android seals a ctl 11 under its own losing
    /// root before it reads the iPhone's opener, then adopts the iPhone's root and seals one under it. A's held keys carry
    /// the root tag A's session ends on, and the losing root's ctl 11, delivered afterwards, never replaces them.
    @Test func aRaceWinnersRootFilesTheKeysAndTheLosersNeverReplacesThem() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try #require(me.nodeId < alice.nodeId, "the iPhone wins the race")
        try fixture.pin(android)
        fixture.engine.accept(alice.nodeId.string)
        fixture.engine.feedPresenceKeys()
        let ours = try #require(fixture.engine.sendDirectMessage("hi", to: alice.nodeId)).id
        let opener = try #require(fixture.transport.written(.chat).last { $0.envelope.id == ours })
        let losing = try keyFrame(android, (10, 1), prekey: try fixture.ourPrekey(), id: "pk-losing", at: now)
        #expect(plaintext(try android.open(opener, from: me, now: now + 1)) != nil, "Android loses and adopts our root")
        fixture.deliver(try keyFrame(android, (20, 2), prekey: try fixture.ourPrekey(), id: "pk-winning", at: now + 2), from: android)
        let endsOn = RatchetCrypto.rootTag(try #require(fixture.engine.ratchet.session(of: alice.nodeId)).root)
        #expect(held(fixture).map(\.generation) == [20])
        #expect(held(fixture).allSatisfy { $0.rootTag == endsOn }, "filed under the root A's session ends on")
        fixture.deliver(losing, from: android)
        #expect(RatchetCrypto.rootTag(try #require(fixture.engine.ratchet.session(of: alice.nodeId)).root) == endsOn)
        #expect(held(fixture).allSatisfy { $0.rootTag == endsOn } && held(fixture).map(\.generation) == [20])
        #expect(fixture.engine.presenceKeyCounts.replaced == 0)
    }
}
