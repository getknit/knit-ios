import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// With the ratchet's switch off, every group frame of ours is today's v1, whatever the members advertise (ADR 2026-10.5sk9,
/// phase P6b's guard): the same draws from the injected generator, the same frames but for a seal's own random key and
/// nonce, the same plaintext, no seed DM, no floor, and nothing in the group store, through a send, a reaction, a link-up,
/// the re-offer and the heal, a departure, a rejoin and our own leave.
@Suite struct MeshEngineGroupSwitchTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }

    /// Drives `fixture` through the same group traffic, and answers the group.
    private func drive(_ fixture: EngineFixture) throws -> GroupInfo {
        let group = fixture.holdGroup(with: [alice, carol])
        fixture.transport.clear()
        _ = try #require(fixture.engine.sendGroupMessage("one", to: group.id))
        _ = try #require(fixture.engine.sendGroupMessage("two", to: group.id))
        fixture.deliver(try alice.groupMessage("hers", in: group, to: [me, carol], id: "gm-alice", sentAt: now), from: alice)
        _ = try #require(fixture.engine.react(to: "gm-alice", with: "\u{1F525}"))
        fixture.link(alice)
        fixture.advance(MeshConfiguration().healMilliseconds)
        fixture.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
        _ = try #require(fixture.engine.sendGroupMessage("three", to: group.id))
        fixture.deliver(try carol.groupUpdate(group, id: "carol-back", sentAt: now + 2), from: carol)
        _ = try #require(fixture.engine.sendGroupMessage("four", to: group.id))
        #expect(fixture.engine.leaveGroup(group.id))
        return group
    }

    @Test func withTheSwitchOffEveryGroupFrameIsTodaysV1AndTheGroupStoreHoldsNothing() throws {
        let ring = try PrekeyRing.load(for: me.keys, from: KeptSecretStore(me.keys.storedForm))
        let switchedOff = EngineFixture(me, prekeys: ring)
        let today = EngineFixture(me)
        for peer in [alice, carol] {
            switchedOff.deliver(try AndroidPeer(peer).profile(publishedAt: now), from: peer)
            today.deliver(try peer.profile(publishedAt: now, capabilities: 0xF), from: peer)
        }
        #expect(switchedOff.stores.peers.peer(carol.nodeId)?.prekey != nil, "ratchet Androids, their prekeys pinned")
        let group = try drive(switchedOff)
        _ = try drive(today)

        let ours = switchedOff.transport.written
        let theirs = today.transport.written
        #expect(ours.map(\.envelope.id) == theirs.map(\.envelope.id), "the same draws, so the same frame ids")
        #expect(ours.map(\.envelope.type) == theirs.map(\.envelope.type) && ours.map(\.to) == theirs.map(\.to))
        #expect(ours.map(\.wire.relay) == theirs.map(\.wire.relay))
        for (sent, before) in zip(ours, theirs) where sent.envelope.type == .chat {
            var sentEnvelope = sent.envelope
            var beforeEnvelope = before.envelope
            sentEnvelope.payload = []
            beforeEnvelope.payload = []
            #expect(sentEnvelope == beforeEnvelope, "the same frame around the seal")
            let enc = try EngineFixture.sealed(sent)
            let was = try EngineFixture.sealed(before)
            #expect(enc.version == EncEnvelope.Version.staticKeys && enc.groupRatchet == nil && enc.keys.map(\.to) == was.keys.map(\.to))
            let thread = sent.envelope.group?.id ?? sent.envelope.recipientId ?? ""
            let header = MessageCrypto.header(
                id: sent.envelope.id, senderId: me.nodeId.string, sentAt: sent.envelope.sentAt, thread: thread)
            #expect(MessageCrypto.open(enc, header: header, as: alice.keys) == MessageCrypto.open(was, header: header, as: alice.keys))
        }
        // Our profile is the one frame whose bytes may differ, by the ring the app always loads: P3's, not this phase's.
        for frame in ours where frame.envelope.type != .chat && frame.envelope.type != .profile {
            let same = theirs.contains { $0.envelope.id == frame.envelope.id && $0.wire.signed == frame.wire.signed }
            #expect(same, "\(frame.envelope.type) byte for byte")
        }
        #expect(switchedOff.stores.groupRatchet.holdings(of: group.id) == .empty, "nothing written to the group store")
        #expect(switchedOff.engine.groupFloors.seeds.isEmpty && switchedOff.engine.groupFloors.rejoins.isEmpty, "no floor")
        #expect(switchedOff.engine.groupCounts == RatchetGroupCounts() && switchedOff.engine.seals == RatchetSealCounts())
        #expect(switchedOff.ratchetRecords(of: alice).session == nil && switchedOff.ratchetRecords(of: carol).session == nil)
    }
}
