import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The router's id gate as the engine meets it (knit-next ADR 2026-10.9qr4, #178, mirrored from knit-next `a81f2050`): a
/// frame whose id is not the shape its type is minted with stops at the door, before the meter, the seen set, the verify,
/// custody, the key request and the relay. Android refuses it at the same point, so a copy this port kept would be
/// re-served to every Android neighbour at every exchange for its custody life.
@Suite struct MeshEngineCanonicalIdTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private let mallory = TestPeer(seed: 9)
    private let start = EngineFixture.start

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    private func isMarked(_ id: String) -> Bool {
        id.utf8.starts(with: Self.byteOrderMark)
    }

    /// Before the gate, a stranger's twin parked for its sender's key and asked a neighbour for it: the gate is what keeps
    /// that work from ever starting. The real id from the same stranger shows the work the twin would have bought.
    @Test func aTwinFromASenderWeHaveNotPinnedLeavesNoTrace() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        fixture.advance(1000)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        let real = frameIdOf("post-1")
        let marked = "\u{FEFF}" + real
        fixture.deliverRefused(try mallory.roomPost("squatted", id: marked, sentAt: start), from: bob)
        fixture.advance(1000)
        #expect(receivedRecords(in: fixture.engine.drainEvents()).isEmpty, "no message event")
        #expect(!fixture.stores.custody.contains(marked) && fixture.stores.custody.liveIds(now: start).allSatisfy { !isMarked($0) })
        #expect(fixture.engine.footprint.parked == 0 && fixture.engine.footprint.missingKeys == 0, "nothing parked for a key")
        #expect(fixture.engine.footprint.seen == 1, "only our own profile is seen")
        #expect(fixture.transport.written.isEmpty, "no key request, no relay")
        #expect(fixture.engine.dropped.isEmpty)
        #expect(fixture.log.all.contains("debug mesh drop chat \(marked) from \(mallory.nodeId): nonCanonical"))

        fixture.deliver(try mallory.roomPost("real", id: real, sentAt: start), from: bob)
        #expect(fixture.engine.footprint.parked == 1, "the real id parks for the key")
        #expect(!fixture.transport.written(.keyRequest).isEmpty, "and asks the neighbours for it")
    }

    /// Android's walkie chunk (`MeshManager.sendCallTalk`, `MeshManager.kt:3380-3388` at knit-next `a81f2050`): unsigned,
    /// sealed to someone else, flooded with ttl 3 under an 11-character id. This port neither sends nor opens one, and
    /// relays it as it did before the gate: dropped here as unsigned, never carried, flooded on.
    @Test func androidsTalkChunkIsRelayedOnceUnderItsShortIdAndNotUnderAnother() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        fixture.advance(1000)
        fixture.transport.clear()
        func talk(_ id: String) -> TestFrame {
            let envelope = RelayEnvelope(
                type: .talk, id: id, senderId: bob.nodeId.string, sentAt: start, recipientId: dave.nodeId.string, payload: [1, 2, 3]
            )
            return TestFrame(wire: WireEnvelope(ttl: 3, relay: true, sig: [], signed: envelope.encoded), envelope: envelope)
        }
        let short = String(frameIdOf("talk-1").prefix(FrameId.talkLength))
        fixture.deliver(talk(short), from: bob)
        fixture.advance(1000)
        #expect(fixture.transport.written(.talk).map(\.to) == [carol.nodeId], "once, to carol, never back to bob")
        #expect(!fixture.stores.custody.contains(short), "never carried")
        #expect(fixture.engine.dropped[.unsigned] == 1)

        fixture.transport.clear()
        let long = String(frameIdOf("talk-2").prefix(FrameId.talkLength + 1))
        fixture.deliverRefused(talk(long), from: bob)
        fixture.advance(1000)
        #expect(fixture.transport.written.isEmpty, "relayed nowhere")
        #expect(fixture.engine.dropped[.unsigned] == 1, "and never reached the drop")
    }

    /// A walkie call between two Android phones whose only path is through us, from a caller we never pinned: the chunk
    /// is still relayed, and we never ask a neighbour for the caller's key, as Android never does (`NO_KEY_REQUEST_TYPES`,
    /// `InboundPipeline.kt:3996` at knit-next `a81f2050`). Before, every chunk asked once per cooldown.
    @Test func aStrangersTalkChunkIsRelayedWithoutAKeyRequest() {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        fixture.advance(1000)
        fixture.transport.clear()
        let id = String(frameIdOf("talk-3").prefix(FrameId.talkLength))
        let envelope = RelayEnvelope(
            type: .talk, id: id, senderId: mallory.nodeId.string, sentAt: start, recipientId: dave.nodeId.string, payload: [1, 2, 3]
        )
        let wire = WireEnvelope(ttl: 3, relay: true, sig: [], signed: envelope.encoded)
        fixture.deliver(TestFrame(wire: wire, envelope: envelope), from: bob)
        fixture.advance(1000)
        #expect(fixture.engine.dropped == [.noSenderKey: 1])
        #expect(fixture.transport.written(.keyRequest).isEmpty, "no key request for the caller")
        #expect(fixture.engine.footprint.parked == 0 && fixture.engine.footprint.missingKeys == 0, "nothing parked or wanted")
        #expect(fixture.transport.written(.talk).map(\.to) == [carol.nodeId], "still relayed, once, to carol")
        #expect(!fixture.stores.custody.contains(id), "never carried")
    }

    /// Our profile's id is the shape every build's gate admits, or no neighbour of either platform would ever pin us.
    @Test func ourOwnProfileIsAdmitted() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        let profile = try #require(fixture.transport.written(.profile).first)
        #expect(profile.envelope.id == FrameId.profileId(sender: alice.nodeId.string, publishedAt: profile.envelope.sentAt))
        #expect(FrameId.admits(profile.envelope))
    }

    /// The port of `CanonicalIdLabTest.aTwinUnderAMarkedIdIsRefusedAndTheRealPostStillReachesEveryone` (knit-next
    /// `mesh/lab/CanonicalIdLabTest.kt` at `a81f2050`). Alice posts in the room while she has no links. Mallory, who knows
    /// the post's id, hands Bob a post of her own, properly signed, under that id with a byte-order mark in front, and it
    /// reaches him first. Bob refuses it at the door; when Alice meets the two of them, her post reaches both and the three
    /// custodies agree, with the twin held and listed nowhere.
    @Test func aTwinUnderAMarkedIdIsRefusedAndTheRealPostStillReachesEveryone() throws {
        let lab = EngineLab([EngineFixture(alice, seed: 31), EngineFixture(bob, seed: 32), EngineFixture(mallory, seed: 33)])
        lab.link(1, 2)
        lab.advance(1000)
        #expect(lab[1].stores.peers.peer(mallory.nodeId) != nil && lab[2].stores.peers.peer(bob.nodeId) != nil, "acquainted")

        lab[0].engine.postToRoom("hello room")
        let real = try #require(lab[0].transport.written(.chat).last?.envelope.id)
        #expect((0...2).allSatisfy { lab[$0].engine.routerCounters.nonCanonical == 0 }, "nothing honest is refused")
        let twin = try lab[2].me.roomPost("squatted", id: "\u{FEFF}" + real, sentAt: lab[2].clock.wallMilliseconds())
        lab[1].deliverRefused(twin, from: lab[2].me)

        lab.link(0, 1)
        lab.link(0, 2)
        lab.advance(1000)
        lab.advance(60_000)

        #expect(lab[1].engine.routerCounters.nonCanonical == 1)
        #expect(lab[0].engine.routerCounters.nonCanonical == 0 && lab[2].engine.routerCounters.nonCanonical == 0)
        let custodies = (0...2).map { Set(lab.liveIds($0)) }
        #expect(custodies[0] == custodies[1] && custodies[1] == custodies[2], "the three custodies agree")
        for index in 0...2 {
            #expect(custodies[index].contains(real), "node \(index) custodies the real post")
            #expect(lab[index].stores.messages.message(real)?.body == "hello room", "node \(index) has alice's words")
            #expect(custodies[index].allSatisfy { !isMarked($0) }, "node \(index) holds no marked id")
            #expect(lab[index].transport.digests.allSatisfy { $0.ids.allSatisfy { !isMarked($0) } }, "node \(index) lists no marked id")
        }
    }
}
