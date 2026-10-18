import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Our DMs sealed with the ratchet, with the switch on (ADR 2026-10.5sk9, phase P5b): `MeshManagerTest`'s dispatch and
/// fallback cases by name (`MeshManagerTest.kt:1947-2259`, at knit-next `cbf2a487`), each sent through the engine and opened
/// by Android's own session layer (``AndroidPeer``). Their inline-ack halves are `MeshEngineInlineAckTests`' (phase P5d), and
/// the group cases P6's.
@Suite struct MeshEngineRatchetSendTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private var now: Int64 { EngineFixture.start }

    /// An engine with the switch on, and Android pinned with `capabilities` and its prekey unless `withPrekey` is false.
    private func rig(capabilities: Int64 = AndroidPeer.capabilities, withPrekey: Bool = true) throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        let profile = try alice.profile(
            name: "Ann", publishedAt: now, capabilities: capabilities, prekey: withPrekey ? android.prekey.info : nil)
        fixture.deliver(profile, from: alice)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, android)
    }

    /// The DM frames the engine wrote to Alice, and the envelope each carries.
    private func sent(_ fixture: EngineFixture) throws -> [(written: Written, enc: EncEnvelope)] {
        try fixture.transport.written(.chat).map { written in
            (written, try #require(try ChatContent(decoding: written.envelope.payload).enc))
        }
    }

    /// What Android reads of `written`, opened by its own session layer.
    private func read(_ written: Written, by android: AndroidPeer, v3: Bool) throws -> MessageContent? {
        let bytes = try #require(plaintext(try android.open(written, from: me, now: now)))
        return v3 ? MessageContentV2.decode(bytes) : try MessageContent(decoding: bytes)
    }

    /// `aDmToARatchetCapablePeerSealsV2` (`MeshManagerTest.kt:1970-1999`): the ratchet's bit and a prekey, no `CAP_CRYPTO_V3`.
    @Test func aDmToARatchetCapablePeerSealsV2() throws {
        let (fixture, android) = try rig(capabilities: 0x5F)
        let record = try #require(fixture.engine.sendDirectMessage("fs hello", to: alice.nodeId))
        #expect(!record.pendingKey && fixture.stores.messages.message(record.id)?.pendingKey == false, "the row is not pendingKey")
        let first = try #require(try sent(fixture).first)
        #expect(first.enc.version == EncEnvelope.Version.ratchet && first.enc.keys.isEmpty && first.enc.nonce.count == 12)
        let header = try #require(first.enc.ratchet)
        #expect(header.se == 1 && header.pe == 0 && header.n == 0)
        #expect(header.initial?.pkid == 1, "the first frame carries the X3DH init")
        #expect(fixture.engine.seals == RatchetSealCounts(dmSealedV2: 1))
        #expect(fixture.engine.drainEvents().contains(.sent(messageId: record.id)))

        // A second DM continues the chain in the same epoch, init still attached (unconfirmed).
        let again = try #require(fixture.engine.sendDirectMessage("again", to: alice.nodeId))
        let second = try #require(try sent(fixture).last)
        #expect(second.written.envelope.id == again.id)
        #expect(second.enc.ratchet?.se == 1 && second.enc.ratchet?.n == 1 && second.enc.ratchet?.initial != nil)
        #expect(try read(first.written, by: android, v3: false)?.body == "fs hello")
        #expect(try read(second.written, by: android, v3: false)?.body == "again")
    }

    /// `aDmToACryptoV3PeerSealsV3` (`MeshManagerTest.kt:2001-2032`): the compact scheme, still signed, still flooded and
    /// carried.
    @Test func aDmToACryptoV3PeerSealsV3() throws {
        let (fixture, android) = try rig()
        let record = try #require(fixture.engine.sendDirectMessage("fs hello", to: alice.nodeId))
        let only = try #require(try sent(fixture).first)
        #expect(only.written.wire.sig.count == 64 && only.written.wire.relay, "a flooded DM keeps its signature")
        #expect(me.keys.bundle.isValidSignature(only.written.wire.sig, for: only.written.wire.signed))
        #expect(only.enc.version == EncEnvelope.Version.compactRatchet)
        #expect(only.enc.nonce.isEmpty, "the nonce is derived, the field rides empty")
        #expect(only.enc.keys.isEmpty && only.enc.ratchet != nil)
        #expect(fixture.engine.seals == RatchetSealCounts(dmSealedV2: 1, dmSealedV3: 1), "v3 is still a ratchet seal")
        #expect(fixture.stores.custody.frame(record.id, now: now)?.signed == only.written.wire.signed, "carried as ours")
        #expect(try read(only.written, by: android, v3: true)?.body == "fs hello")
    }

    /// `aDmToAPeerWithoutTheCapabilityStaysV1` (`MeshManagerTest.kt:2072-2086`): a pre-ratchet build.
    @Test func aDmToAPeerWithoutTheCapabilityStaysV1() throws {
        let (fixture, _) = try rig(capabilities: 0xF, withPrekey: false)
        let record = try #require(fixture.engine.sendDirectMessage("legacy", to: alice.nodeId))
        let only = try #require(try sent(fixture).first)
        #expect(only.enc.version == EncEnvelope.Version.staticKeys && only.enc.ratchet == nil)
        #expect(only.enc.keys.map(\.to) == [alice.nodeId.string])
        #expect(fixture.engine.seals == RatchetSealCounts())
        #expect(!fixture.engine.drainEvents().contains(.sent(messageId: record.id)), "sent at once, as before")
        #expect(fixture.ratchetRecords(of: alice).session == nil)
    }

    /// `aCapableClaimWithoutAPrekeyFallsBackToV1AndCounts` (`MeshManagerTest.kt:2088-2108`), and the seal half of
    /// `aV1FallbackGivesTheInlineAcksBack` (`:1947-1968`): the bit with no prekey and no session goes v1 at once, counted,
    /// and once a prekey pins, the next DM takes the ratchet while the first is never upgraded.
    @Test func aCapableClaimWithoutAPrekeyFallsBackToV1AndCounts() throws {
        let (fixture, android) = try rig(withPrekey: false)
        let first = try #require(fixture.engine.sendDirectMessage("careful", to: alice.nodeId))
        let sealed = try #require(try sent(fixture).first)
        #expect(sealed.enc.version == EncEnvelope.Version.staticKeys)
        #expect(MessageCrypto.open(sealed.enc, header: header(of: sealed.written), as: alice.keys)?.body == "careful")
        #expect(fixture.engine.seals == RatchetSealCounts(dmSealedV1Fallback: 1))
        #expect(fixture.stores.messages.message(first.id)?.pendingKey == false)
        #expect(fixture.ratchetRecords(of: alice).session == nil, "nothing persisted")

        fixture.clock.advance(1000)
        fixture.deliver(try android.profile(publishedAt: now + 1000), from: alice)
        let next = try #require(fixture.engine.sendDirectMessage("now sealed", to: alice.nodeId))
        let ids = fixture.transport.written(.chat).map(\.envelope.id)
        #expect(ids == [first.id, next.id], "the first DM is never sent again")
        #expect(try sent(fixture).last?.enc.version == EncEnvelope.Version.compactRatchet)
    }

    /// `aDmToALowOrderPrekeyFallsBackToV1AndCounts` (#172, `MeshManagerTest.kt` at `4f3cd995`): a peer's prekey X25519
    /// refuses, signed by its own key. Since #172 the profile's intake never pins it (`aSignedLowOrderPrekeyIsNotPinned`,
    /// in `MeshEnginePrekeyIntakeTests`), so the row here is one pinned before that rule, which the facade refuses as
    /// Kotlin's maps Tink's throw to "cannot seal". A chat goes v1, counted, and nothing is persisted or counted toward a
    /// reset.
    @Test func aDmToALowOrderPrekeyFallsBackToV1AndCounts() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let zero = [UInt8](repeating: 0, count: 32)
        let signature = try alice.keys.signature(for: RatchetCrypto.spkSigningBytes(id: 4, pub: zero))
        let lowOrder = PrekeyInfo(id: 4, pub: zero, sig: signature)
        fixture.deliver(try alice.profile(publishedAt: now, capabilities: AndroidPeer.capabilities, prekey: lowOrder), from: alice)
        var row = try #require(fixture.stores.peers.peer(alice.nodeId))
        #expect(row.prekey == nil, "never pinned since #172")
        row.prekey = lowOrder
        fixture.stores.peers.upsert(row)
        fixture.transport.clear()

        _ = try #require(fixture.engine.sendDirectMessage("still reaches you", to: alice.nodeId))
        let only = try #require(try sent(fixture).first)
        #expect(only.enc.version == EncEnvelope.Version.staticKeys)
        #expect(fixture.engine.seals == RatchetSealCounts(dmSealedV1Fallback: 1))
        #expect(fixture.ratchetRecords(of: alice) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
        #expect(fixture.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 0)
    }

    /// The chat's half of `aTickAckingANonCanonicalIdToAV3AuthorFallsBackToV2` (`MeshManagerTest.kt:2056-2070`): a reply
    /// quoting an id the compact codec cannot carry goes v2 to a v3 peer, and Android reads the quote.
    @Test func aDMWithNoCompactFormGoesV2ToAV3Peer() throws {
        let (fixture, android) = try rig()
        let quote = MessageReply(
            messageId: "not-a-frame-id", authorId: alice.nodeId.string, author: "Ann", snippet: "hi", hasAttachment: false)
        _ = try #require(fixture.engine.sendDirectMessage("yes", to: alice.nodeId, replyTo: quote))
        let only = try #require(try sent(fixture).first)
        #expect(only.enc.version == EncEnvelope.Version.ratchet && only.enc.nonce.count == 12)
        #expect(fixture.engine.seals == RatchetSealCounts(dmSealedV2: 1))
        #expect(try read(only.written, by: android, v3: false)?.replyTo?.messageId == "not-a-frame-id")
    }

    /// A DM that waited for its key goes with the ratchet once Android's profile pins (`flushPendingFor`,
    /// `MeshManager.kt:3345-3352`), announced as sent, under its own id and stamp.
    @Test func aDMThatWaitedForTheKeyIsSealedWithTheRatchetWhenItPins() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        let waiting = try #require(fixture.engine.sendDirectMessage("later", to: alice.nodeId))
        #expect(waiting.pendingKey && fixture.transport.written(.chat).isEmpty)
        _ = fixture.engine.drainEvents()

        fixture.clock.advance(5000)
        try fixture.pin(android)
        let only = try #require(try sent(fixture).first)
        #expect(only.written.envelope.id == waiting.id && only.written.envelope.sentAt == waiting.sentAt)
        #expect(only.enc.version == EncEnvelope.Version.compactRatchet)
        #expect(fixture.stores.messages.message(waiting.id)?.pendingKey == false)
        #expect(fixture.engine.drainEvents().contains(.sent(messageId: waiting.id)))
        #expect(try read(only.written, by: android, v3: true)?.body == "later")
    }

    /// With the switch on, a DM that waited for a peer whose profile then pins without the ratchet's bit goes v1 at that
    /// pin, to the bundle the flush's one read gave, announced as sent and counted as no fallback: a pre-ratchet build.
    @Test func aDMThatWaitedForAPeerWithoutTheBitGoesV1WhenItPins() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let waiting = try #require(fixture.engine.sendDirectMessage("for an old build", to: alice.nodeId))
        #expect(waiting.pendingKey && fixture.transport.written(.chat).isEmpty)
        _ = fixture.engine.drainEvents()

        fixture.clock.advance(5000)
        fixture.deliver(try alice.profile(publishedAt: now + 5000, capabilities: 0xF), from: alice)
        let only = try #require(try sent(fixture).first)
        #expect(only.written.envelope.id == waiting.id && only.written.envelope.sentAt == waiting.sentAt)
        #expect(only.enc.version == EncEnvelope.Version.staticKeys && only.enc.keys.map(\.to) == [alice.nodeId.string])
        #expect(MessageCrypto.open(only.enc, header: header(of: only.written), as: alice.keys)?.body == "for an old build")
        #expect(fixture.stores.messages.message(waiting.id)?.pendingKey == false)
        #expect(fixture.engine.drainEvents().contains(.sent(messageId: waiting.id)))
        #expect(fixture.engine.seals == RatchetSealCounts())
        #expect(fixture.ratchetRecords(of: alice).session == nil)
    }

    /// The pair: Android answers our opener under the session it started, and our session confirms on its answer.
    @Test func androidsAnswerToOurFirstDMConfirmsOurSession() throws {
        let (fixture, android) = try rig()
        _ = try #require(fixture.engine.sendDirectMessage("hello", to: alice.nodeId))
        let opener = try #require(try sent(fixture).first)
        #expect(try read(opener.written, by: android, v3: true)?.body == "hello")
        let theirs = try #require(android.session(with: me))
        #expect(theirs.confirmed && !theirs.weAreInitiator)

        let answer = try android.dm("hi back", to: me, prekey: try fixture.ourPrekey(), id: "answer", sentAt: now + 1, v3: true)
        fixture.deliver(answer, from: android)
        let ours = try #require(fixture.ratchetRecords(of: alice).session)
        #expect(fixture.stores.messages.message("answer")?.body == "hi back")
        #expect(ours.confirmed && ours.weAreInitiator && ours.root == theirs.root && ours.establishedAt == theirs.establishedAt)
    }

    /// The v1 header a frame's AAD is.
    private func header(of written: Written) -> [UInt8] {
        let envelope = written.envelope
        return MessageCrypto.header(
            id: envelope.id, senderId: envelope.senderId, sentAt: envelope.sentAt, thread: envelope.recipientId ?? "")
    }
}
