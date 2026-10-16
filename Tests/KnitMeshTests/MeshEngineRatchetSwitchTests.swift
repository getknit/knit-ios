import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// With the ratchet's switch off, every DM seal is today's v1, whatever the peer advertises (ADR 2026-10.5sk9, the guard
/// the DM phase owes): the same draws from the injected generator, the same frames but for the seal's own random key and
/// nonce, the same plaintext, and nothing in the ratchet's tables.
@Suite struct MeshEngineRatchetSwitchTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let bob = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }

    /// An engine with the switch off that keeps a ring, as the app always loads one.
    private func off() throws -> EngineFixture {
        let ring = try PrekeyRing.load(for: me.keys, from: KeptSecretStore(me.keys.storedForm))
        return EngineFixture(me, prekeys: ring)
    }

    @Test func withTheSwitchOffEveryDMSealIsTodaysV1AndTheRatchetHoldsNothing() throws {
        let switchedOff = try off()
        let today = EngineFixture(me)
        let android = try AndroidPeer(alice)
        switchedOff.deliver(try android.profile(publishedAt: now), from: alice)
        today.deliver(try alice.profile(publishedAt: now, capabilities: 0xF), from: alice)
        #expect(switchedOff.stores.peers.peer(alice.nodeId)?.prekey != nil, "a ratchet Android, its prekey pinned")
        for fixture in [switchedOff, today] {
            fixture.transport.clear()
            _ = fixture.engine.sendDirectMessage("one", to: alice.nodeId)
            _ = fixture.engine.sendDirectMessage("two", to: alice.nodeId)
            // One that waits for its key, sealed when Bob's profile pins.
            _ = fixture.engine.sendDirectMessage("for bob", to: bob.nodeId)
            fixture.deliver(try bob.profile(publishedAt: now, capabilities: 0x15F, prekey: try bob.prekey(id: 1)), from: bob)
        }

        let ours = switchedOff.transport.written
        let theirs = today.transport.written
        #expect(ours.map(\.envelope.id) == theirs.map(\.envelope.id), "the same draws, so the same frame ids")
        #expect(ours.map(\.envelope.type) == theirs.map(\.envelope.type) && ours.map(\.to) == theirs.map(\.to))
        for (sent, before) in zip(ours, theirs) where sent.envelope.type == .chat {
            var sentEnvelope = sent.envelope
            var beforeEnvelope = before.envelope
            sentEnvelope.payload = []
            beforeEnvelope.payload = []
            #expect(sentEnvelope == beforeEnvelope && sent.wire.relay == before.wire.relay, "the same frame around the seal")
            let enc = try #require(try ChatContent(decoding: sent.envelope.payload).enc)
            let was = try #require(try ChatContent(decoding: before.envelope.payload).enc)
            #expect(enc.version == EncEnvelope.Version.staticKeys && enc.ratchet == nil && enc.nonce.count == 12)
            #expect(enc.keys.map(\.to) == was.keys.map(\.to) && enc.ct.count == was.ct.count)
            let recipient = sent.envelope.recipientId == alice.nodeId.string ? alice : bob
            let header = MessageCrypto.header(
                id: sent.envelope.id, senderId: me.nodeId.string, sentAt: sent.envelope.sentAt, thread: recipient.nodeId.string)
            #expect(
                MessageCrypto.open(enc, header: header, as: recipient.keys) == MessageCrypto.open(was, header: header, as: recipient.keys))
        }
        for peer in [alice, bob] {
            #expect(
                switchedOff.ratchetRecords(of: peer) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
        }
        #expect(switchedOff.engine.seals == RatchetSealCounts())
    }

    /// With the switch off, a peer's reset never reaches the ratchet, so nothing is sealed again: the re-seal's v1 arm,
    /// which a peer pinned without the bit takes with the switch on, cannot sign an id a second time here (the P5b crypto
    /// review). The reset is sealed to a prekey of ours, which the engine never even looks for.
    @Test func withTheSwitchOffAPeersResetSealsNothingAgain() throws {
        let switchedOff = try off()
        let android = try AndroidPeer(alice)
        switchedOff.deliver(try android.profile(publishedAt: now), from: alice)
        _ = try #require(switchedOff.engine.sendDirectMessage("still v1", to: alice.nodeId))
        #expect(switchedOff.transport.written(.chat).count == 1)

        switchedOff.clock.advance(60_000)
        let prekey = try #require(PeerPrekey(verifying: try me.prekey(id: 1), signedBy: me.keys.bundle))
        switchedOff.deliver(try android.resetDm(to: me, prekey: prekey, id: "android-reset", at: now + 60_000), from: alice)
        #expect(switchedOff.transport.written(.chat).count == 1, "no chat frame: nothing sealed again")
        #expect(switchedOff.ratchetRecords(of: alice) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
        #expect(switchedOff.engine.seals == RatchetSealCounts())
    }
}
