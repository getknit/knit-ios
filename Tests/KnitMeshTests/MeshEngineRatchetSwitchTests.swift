import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// With the ratchet's switch off, every DM seal is today's v1, and every receipt and tick today's cleartext one, whatever the
/// peer advertises (ADR 2026-10.5sk9, the guard the DM phase owes): the same draws from the injected generator, the same
/// frames but for a seal's own random key and nonce, the same plaintext, and nothing in the ratchet's tables.
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

    /// The receipts' and ticks' leg of the guard, with the seams P5d ships (the P5c crypto review's finding 1): toward an
    /// Android phone whose profile carries `0x15F` and a signed prekey, linked, then away through a carrier, past the batch's
    /// debounce, a heal and the link-up, every receipt and tick is the one a pre-ratchet peer gets today, frame for frame from
    /// the same draws. Nothing is sealed toward it, nothing reaches the ratchet's tables, and our cleartext receipts purge
    /// both DMs from our custody, as they always have.
    @Test func withTheSwitchOffReceiptsAndTicksTowardARatchetAndroidAreTodays() throws {
        let switchedOff = try off()
        let today = EngineFixture(me)
        let android = try AndroidPeer(alice)
        switchedOff.deliver(try android.profile(publishedAt: now), from: alice)
        today.deliver(try alice.profile(publishedAt: now, capabilities: 0xF), from: alice)
        let group = roster([alice, bob, me], createdBy: alice)
        // The same frames to both: a v1 seal draws its own key, so each is sealed once.
        let linked = [
            try alice.directMessage("hi", to: me, id: "dm-1", sentAt: now),
            try alice.roomPost("room", id: "post-1", sentAt: now),
            try alice.groupMessage("group", in: group, to: [bob, me], id: "gm-1", sentAt: now),
        ]
        let away = [
            try alice.directMessage("again", to: me, id: "dm-2", sentAt: now + 1),
            try alice.roomPost("room again", id: "post-2", sentAt: now + 1),
            try alice.groupMessage("group again", in: group, to: [bob, me], id: "gm-2", sentAt: now + 1),
        ]
        for fixture in [switchedOff, today] {
            fixture.link(bob)
            fixture.link(alice)
            fixture.transport.clear()
            for frame in linked {
                fixture.deliver(frame, from: alice)
            }
            fixture.unlink(alice)
            for frame in away {
                fixture.deliver(frame, from: bob)
            }
            fixture.advance(AckSync.batchDebounceMilliseconds)
            fixture.advance(MeshConfiguration().healMilliseconds)
            fixture.link(alice)
        }

        // Ours: what each engine signed. Alice's profile, which differs on purpose, is relayed as it came.
        let mine = ExactKey(me.nodeId.string)
        let ours = switchedOff.transport.written.filter { ExactKey($0.envelope.senderId) == mine }
        let theirs = today.transport.written.filter { ExactKey($0.envelope.senderId) == mine }
        #expect(ours.map(\.envelope.id) == theirs.map(\.envelope.id), "the same draws, so the same frame ids")
        for (sent, before) in zip(ours, theirs) {
            #expect(sent.envelope.type == before.envelope.type && sent.to == before.to && sent.wire.relay == before.wire.relay)
            #expect(sent.wire.signed == before.wire.signed, "\(sent.envelope.type.rawValue) \(sent.envelope.id): today's bytes")
        }
        let acked = try switchedOff.transport.written(.receipt).map { try ReceiptContent(decoding: $0.envelope.payload).ackId }
        #expect(Set(acked) == ["dm-1", "post-1", "gm-1", "dm-2", "post-2", "gm-2"] && acked.count == 6)
        #expect(ours.allSatisfy { $0.envelope.type != .chat }, "no DM-form chat of ours")
        #expect(switchedOff.ratchetRecords(of: alice) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
        #expect(!switchedOff.stores.custody.contains("dm-1") && !switchedOff.stores.custody.contains("dm-2"), "purged, as today")
    }

    /// The presentation plane's leg of the guard (phase P5e), with the real seals: toward an Android phone whose profile
    /// carries `0x15F` and a signed prekey, a reaction and its retraction, a profile edit and the heal after it, and a ratchet
    /// DM carrying Android's init are, frame for frame from the same draws, what a pre-ratchet peer gets today. Nothing of
    /// ours is DM-form, the ratchet DM drops unopened, so no init is answered, and nothing reaches the ratchet's tables.
    @Test func withTheSwitchOffReactionsProfilesAndAnswersTowardARatchetAndroidAreTodays() throws {
        let switchedOff = try off()
        let today = EngineFixture(me)
        let android = try AndroidPeer(alice)
        switchedOff.deliver(try android.profile(publishedAt: now), from: alice)
        today.deliver(try alice.profile(publishedAt: now, capabilities: 0xF), from: alice)
        // The same frames to both: a v1 DM to react to, and a ratchet DM whose init rides, sealed to a prekey of ours.
        let prekey = try #require(PeerPrekey(verifying: try me.prekey(id: 1), signedBy: me.keys.bundle))
        let frames = [
            try alice.directMessage("hi", to: me, id: "dm-1", sentAt: now),
            try android.dm("sealed", to: me, prekey: prekey, id: "dm-2", sentAt: now),
        ]
        for fixture in [switchedOff, today] {
            fixture.transport.clear()
            for frame in frames {
                fixture.deliver(frame, from: alice)
            }
            _ = fixture.engine.react(to: "dm-1", with: "👍")
            _ = fixture.engine.react(to: "dm-1", with: "👍")
            fixture.engine.updateProfile(name: "Dana", status: "", openToChat: false)
            fixture.advance(MeshConfiguration().healMilliseconds)
        }

        let mine = ExactKey(me.nodeId.string)
        let ours = switchedOff.transport.written.filter { ExactKey($0.envelope.senderId) == mine }
        let theirs = today.transport.written.filter { ExactKey($0.envelope.senderId) == mine }
        #expect(ours.map(\.envelope.id) == theirs.map(\.envelope.id), "the same draws, so the same frame ids")
        for (sent, before) in zip(ours, theirs) {
            #expect(sent.envelope.type == before.envelope.type && sent.to == before.to && sent.wire.relay == before.wire.relay)
            #expect(sent.wire.signed == before.wire.signed, "\(sent.envelope.type.rawValue) \(sent.envelope.id): today's bytes")
        }
        #expect(ours.allSatisfy { $0.envelope.type != .chat }, "no DM-form chat of ours: no sealed reaction, profile or answer")
        #expect(switchedOff.transport.written(.reaction).count == 2 && switchedOff.transport.written(.profile).count >= 1)
        #expect(switchedOff.engine.dropped[.cannotOpen] == 1, "the ratchet DM drops unopened, as today")
        #expect(switchedOff.ratchetRecords(of: alice) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
        #expect(switchedOff.engine.seals == RatchetSealCounts() && switchedOff.engine.answers == RatchetAnswerCounts())
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
