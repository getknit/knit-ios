import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Inline acks on our DMs with the ratchet's switch on (ADR 2026-10.5sk9, phase P5d; `inlineAcksFor` and `sendChat`,
/// `MeshManager.kt:2004-2026` and `:1185-1202`, at `cbf2a487`): a DM's first seal toward a peer whose pinned profile carries
/// `CAP_INLINE_ACK` carries the room ticks waiting for a ride toward it, inside the ratchet's plaintext, as many as Kotlin's
/// LoRa budget leaves room for, at most four, said to have ridden only once its unit commits with the ratchet, and given back
/// with their stamps otherwise. `MeshManagerTest`'s inline cases by name, read by Android's session layer. This port has no
/// DM coalescer, so the DM-ack halves of `aDmToAnInlineAckCapablePeerCarriesThePendingAcksAndOneWithoutTheBitDoesNot` and
/// `aRoomTickWaitingForARideTakesTheSlotsADmAckLeaves` are the room ticks' alone.
@Suite struct MeshEngineInlineAckTests {
    /// The iPhone, whose node id sorts first, so a reset race it is in is its own to win.
    private let me: TestPeer
    private let alice: TestPeer
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private static let minute: Int64 = 60_000
    private var now: Int64 { EngineFixture.start }

    init() {
        let pair = [TestPeer(seed: 1), TestPeer(seed: 2)].sorted { $0.nodeId < $1.nodeId }
        me = pair[0]
        alice = pair[1]
    }

    /// The iPhone with the switch on, Carol linked, and Alice an Android phone pinned with `capabilities` and its prekey
    /// unless `withPrekey` is false, and away.
    private func rig(
        capabilities: Int64 = AndroidPeer.capabilities, withPrekey: Bool = true, stores: MeshStores = .inMemory()
    ) throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        let profile = try alice.profile(
            name: "Ann", publishedAt: now, capabilities: capabilities, prekey: withPrekey ? android.prekey.info : nil)
        fixture.deliver(profile, from: alice)
        fixture.link(carol)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, android)
    }

    /// A canonical frame id, which the compact layout carries as 16 raw bytes.
    private func canonicalId(_ seed: UInt64) -> String {
        var generator = SeededGenerator(seed: seed)
        return FrameId.generate(using: &generator)
    }

    /// `author`'s room posts, Alice's unless told, delivered through Carol while the author is away: each one's tick waits
    /// in the author's ride hold.
    private func waitingTicks(_ count: Int, in fixture: EngineFixture, by author: TestPeer? = nil, seed: UInt64 = 100) throws -> [String] {
        try (0..<count).map { index in
            let id = canonicalId(seed + UInt64(index))
            fixture.deliver(try (author ?? alice).roomPost("room \(index)", id: id, sentAt: now + Int64(index)), from: carol)
            return id
        }
    }

    /// The last DM frame the engine wrote under `id`.
    private func frame(_ id: String, in fixture: EngineFixture) throws -> Written {
        try #require(fixture.transport.written(.chat).last { $0.envelope.id == id }, "\(id) went")
    }

    /// How many bytes of ciphertext the DM `id` carries.
    private func ciphertextSize(_ id: String, in fixture: EngineFixture) throws -> Int {
        try #require(try ChatContent(decoding: try frame(id, in: fixture).envelope.payload).enc).ct.count
    }

    /// What `android` reads of `written`, opened by its own session layer.
    private func read(_ written: Written, by android: AndroidPeer, at time: Int64) throws -> MessageContent? {
        let enc = try #require(try ChatContent(decoding: written.envelope.payload).enc)
        let bytes = try #require(plaintext(try android.open(written, from: me, now: time)))
        return enc.version == EncEnvelope.Version.compactRatchet ? MessageContentV2.decode(bytes) : try MessageContent(decoding: bytes)
    }

    // MARK: MeshManagerTest

    /// `aDmToAnInlineAckCapablePeerCarriesThePendingAcksAndOneWithoutTheBitDoesNot` (`MeshManagerTest.kt:1765-1810`), in v2's
    /// named layout as Kotlin's measures it: two 22-character ids grow the ciphertext by `INLINE_ACK_BYTES` each and the
    /// `acks` key's header, nothing else, they leave the ride hold, and a peer whose profile lacks the bit keeps its riders.
    @Test func aDmToAnInlineAckCapablePeerCarriesTheWaitingTicksAndOneWithoutTheBitDoesNot() throws {
        let (fixture, android) = try rig(capabilities: 0x5F)
        let bare = try #require(fixture.engine.sendDirectMessage("plain", to: alice.nodeId)).id
        let posts = try waitingTicks(2, in: fixture)
        let carrying = try #require(fixture.engine.sendDirectMessage("plain", to: alice.nodeId)).id
        let grew = try ciphertextSize(carrying, in: fixture) - ciphertextSize(bare, in: fixture)
        #expect(
            (2 * RatchetOutbound.inlineAckBytes)...(2 * RatchetOutbound.inlineAckBytes + 12) ~= grew, "the two ride inside (+\(grew) B)")
        #expect(fixture.engine.ackSync.ridingFor(alice.nodeId) == 0, "taken out of the ride hold: no tick will follow")
        let at = fixture.clock.wallMilliseconds()
        #expect(try read(try frame(bare, in: fixture), by: android, at: at)?.acks == nil)
        #expect(try read(try frame(carrying, in: fixture), by: android, at: at)?.acks == posts)
        #expect(fixture.engine.seals == RatchetSealCounts(dmSealedV2: 2), "a reply is our own DM, never a tick")

        // Dave's profile lacks the bit: he is never sent one, and keeps his ride.
        let quiet = try AndroidPeer(dave)
        let profile = try dave.profile(publishedAt: at, capabilities: AndroidPeer.capabilities & ~0x40, prekey: quiet.prekey.info)
        fixture.deliver(profile, from: dave)
        _ = try waitingTicks(1, in: fixture, by: dave, seed: 200)
        let toDave = try #require(fixture.engine.sendDirectMessage("plain", to: dave.nodeId)).id
        let enc = try #require(try ChatContent(decoding: try frame(toDave, in: fixture).envelope.payload).enc)
        #expect(enc.version == EncEnvelope.Version.compactRatchet)
        let opened = try quiet.open(try frame(toDave, in: fixture), from: me, now: at)
        #expect(plaintext(opened).flatMap(MessageContentV2.decode)?.acks == nil)
        #expect(fixture.engine.ackSync.ridingFor(dave.nodeId) == 1)
    }

    /// `aDmToACryptoV3PeerSealsV3`'s inline half (`MeshManagerTest.kt:2026-2034`) and `aRoomTickWaitingForARideTakesTheSlotsADmAckLeaves`
    /// (`:1817-1832`): the compact arm carries them too, and the room's ticks take every slot, at most four.
    @Test func inlineAcksRideTheV3ArmUpToFour() throws {
        let (fixture, android) = try rig()
        let posts = try waitingTicks(5, in: fixture)
        let id = try #require(fixture.engine.sendDirectMessage("reply", to: alice.nodeId)).id
        let written = try frame(id, in: fixture)
        let enc = try #require(try ChatContent(decoding: written.envelope.payload).enc)
        #expect(enc.version == EncEnvelope.Version.compactRatchet && enc.nonce.isEmpty)
        let content = try read(written, by: android, at: fixture.clock.wallMilliseconds())
        #expect(content?.body == "reply" && content?.acks == Array(posts.prefix(RatchetOutbound.maxInlineAcks)), "the four oldest")
        #expect(fixture.engine.ackSync.ridingFor(alice.nodeId) == 1, "the fifth waits for the next carrier")
        #expect(fixture.engine.seals == RatchetSealCounts(dmSealedV2: 1, dmSealedV3: 1))
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsRidden: 4), "the four that rode, as Android counts them")
    }

    /// `aV1FallbackGivesTheInlineAcksBack` (`MeshManagerTest.kt:1945-1968`): the bits without a prekey, so the seal falls
    /// back to v1, whose reader never looks for acks: they go back to their hold, each with its stamp.
    @Test func aV1FallbackGivesTheInlineAcksBack() throws {
        let (fixture, _) = try rig(withPrekey: false)
        _ = try waitingTicks(2, in: fixture)
        let stamps = try #require(fixture.engine.ackSync.riding[alice.nodeId]?.map(\.at))
        fixture.clock.advance(1000)
        let record = try #require(fixture.engine.sendDirectMessage("careful", to: alice.nodeId))
        let enc = try #require(try ChatContent(decoding: try frame(record.id, in: fixture).envelope.payload).enc)
        #expect(enc.version == EncEnvelope.Version.staticKeys, "v1")
        let header = MessageCrypto.header(id: record.id, senderId: me.nodeId.string, sentAt: record.sentAt, thread: alice.nodeId.string)
        let opened = MessageCrypto.open(enc, header: header, as: alice.keys)
        #expect(opened?.body == "careful" && opened?.acks == nil, "the v1 content carries none")
        #expect(fixture.engine.ackSync.riding[alice.nodeId]?.map(\.at) == stamps, "given back, with their stamps")
        #expect(fixture.engine.seals == RatchetSealCounts(dmSealedV1Fallback: 1))
        #expect(fixture.engine.receipts == RatchetReceiptCounts(), "none rode")
    }

    // MARK: Units that do not commit, flushes and re-seals

    /// A send unit a store fails, over both store kinds: nothing goes on the air, and the room tick it took goes back with
    /// its stamp. The heal seals the DM again as a flush, which carries no inline acks, so the tick still waits.
    @Test(arguments: StoreKind.allCases)
    func aSendUnitThatFailsGivesTheInlineAcksBackAndTheHealsFlushCarriesNone(kind: StoreKind) throws {
        let directory = scratchDirectory("inline-unit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let (fixture, android) = try rig(stores: stores)
        _ = try waitingTicks(1, in: fixture)
        let stamp = try #require(fixture.engine.ackSync.riding[alice.nodeId]?.first?.at)
        fixture.clock.advance(1000)

        refusing.refusesWrites = true
        let record = try #require(fixture.engine.sendDirectMessage("first", to: alice.nodeId))
        refusing.refusesWrites = false
        #expect(record.pendingKey && fixture.transport.written(.chat).isEmpty, "waiting, and nothing on the air")
        #expect(fixture.engine.ackSync.riding[alice.nodeId]?.map(\.at) == [stamp], "the tick back, with its stamp")

        fixture.advance(MeshConfiguration().healMilliseconds)
        let content = try read(try frame(record.id, in: fixture), by: android, at: fixture.clock.wallMilliseconds())
        #expect(content?.body == "first" && content?.acks == nil, "a flush carries none")
        #expect(fixture.engine.ackSync.ridingFor(alice.nodeId) == 1)
    }

    /// The re-seal after a reset carries none either, as Kotlin's `resealAndFlood` carries none: only a DM's first seal does.
    /// The race is the iPhone's to win (`aResetRaceTheIPhoneWinsReSealsEachUnackedDMOnce`'s shape), so its re-seal goes under
    /// its own init, which Android adopts as it reads it.
    @Test func theReSealAfterAResetCarriesNoInlineAcks() throws {
        let (fixture, android) = try rig()
        let first = try waitingTicks(2, in: fixture)
        let id = try #require(fixture.engine.sendDirectMessage("one", to: alice.nodeId)).id
        let later = try waitingTicks(1, in: fixture, seed: 300)
        #expect(fixture.engine.ackSync.ridingFor(alice.nodeId) == later.count)

        fixture.clock.advance(Self.minute)
        let reset = try android.resetDm(to: me, prekey: try fixture.ourPrekey(), id: "android-reset", at: now + Self.minute)
        fixture.deliver(reset, from: android)
        let seals = fixture.transport.written(.chat).filter { $0.envelope.id == id }
        #expect(seals.count == 2, "sealed again once")
        let original = try #require(seals.first)
        let reseal = try #require(seals.last)
        let at = fixture.clock.wallMilliseconds()
        #expect(try read(reseal, by: android, at: at)?.acks == nil, "the re-seal carries none")
        #expect(fixture.engine.ackSync.ridingFor(alice.nodeId) == later.count, "and the later tick still waits")
        #expect(try read(original, by: android, at: at)?.acks == first, "where the first seal carried its own")
    }

    /// Kotlin's LoRa body budget for a DM (`LoraSizeHint`, `MeshManager.kt:2015-2018`): a long body leaves room for fewer,
    /// and one that fills it for none, so no tick waits on a frame that would not fit Android's long-range hop.
    @Test func onlyAsManyRideAsTheBudgetLeaves() throws {
        let (fixture, android) = try rig()
        _ = try waitingTicks(3, in: fixture)
        // 320 bytes of budget, 270 of body: room for two at 23 bytes each.
        let long = try #require(fixture.engine.sendDirectMessage(String(repeating: "a", count: 270), to: alice.nodeId)).id
        let at = fixture.clock.wallMilliseconds()
        #expect(try read(try frame(long, in: fixture), by: android, at: at)?.acks?.count == 2)
        #expect(fixture.engine.ackSync.ridingFor(alice.nodeId) == 1)
        let full = try #require(fixture.engine.sendDirectMessage(String(repeating: "b", count: 320), to: alice.nodeId)).id
        #expect(try read(try frame(full, in: fixture), by: android, at: at)?.acks == nil, "no room left")
        #expect(fixture.engine.ackSync.ridingFor(alice.nodeId) == 1)
    }
}
