import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A ratchet DM's send unit, over both store kinds (ADR 2026-10.5sk9, phase P5b): the seal, its signature, the cleared wait
/// and our custody's copy commit together, and nothing leaves before they do. A unit that fails leaves the row waiting,
/// nothing on the air and no chain advanced, so the seal the heal makes next is the one Android opens.
@Suite struct MeshEngineRatchetSendUnitTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private var now: Int64 { EngineFixture.start }

    /// What Android reads of the DM `id` the engine sent, and how many such frames went.
    private func androidReads(_ id: String, from fixture: EngineFixture, _ android: AndroidPeer) throws -> (body: String?, frames: Int) {
        let frames = fixture.transport.written(.chat).filter { $0.envelope.id == id }
        let last = try #require(frames.last)
        let bytes = try #require(plaintext(try android.open(last, from: me, now: fixture.clock.wallMilliseconds())))
        return (MessageContentV2.decode(bytes)?.body, frames.count)
    }

    @Test(arguments: StoreKind.allCases)
    func aStoreThatFailsMidSendLeavesTheRowWaitingAndTheHealSendsIt(kind: StoreKind) throws {
        let directory = scratchDirectory("send-unit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let iphone = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        _ = iphone.engine.drainEvents()
        iphone.transport.clear()

        refusing.refusesWrites = true
        let record = try #require(iphone.engine.sendDirectMessage("first", to: alice.nodeId))
        refusing.refusesWrites = false
        #expect(record.pendingKey && stores.messages.message(record.id)?.pendingKey == true, "saved, still waiting")
        #expect(iphone.transport.written(.chat).isEmpty, "nothing on the air")
        #expect(!stores.custody.contains(record.id), "our custody's copy went with the unit")
        #expect(stores.ratchet.records(of: alice.nodeId).session == nil, "no chain advanced")
        #expect(iphone.engine.seals == RatchetSealCounts())
        #expect(!iphone.engine.drainEvents().contains(.sent(messageId: record.id)))

        iphone.advance(MeshConfiguration().healMilliseconds)
        #expect(stores.messages.message(record.id)?.pendingKey == false)
        #expect(iphone.engine.drainEvents().contains(.sent(messageId: record.id)))
        #expect(try androidReads(record.id, from: iphone, android) == ("first", 1), "sent once, and it opens")
        #expect(
            stores.custody.frame(record.id, now: iphone.clock.wallMilliseconds())?.signed
                == iphone.transport.written(.chat).last?.wire.signed)

        let next = try #require(iphone.engine.sendDirectMessage("second", to: alice.nodeId))
        #expect(try androidReads(next.id, from: iphone, android) == ("second", 1), "the chain goes on from the seal that left")
    }

    /// Owed since the P4a reviews: a send nested in a unit its caller opened, which then fails. The send unit joins the
    /// caller's, so it sends nothing before that unit commits, and the failure takes the seal, the cleared wait and the
    /// custody copy with it. The next seal, outside, is the one Android opens.
    @Test(arguments: StoreKind.allCases)
    func aSendNestedInAUnitThatFailsPutsNothingOnTheAir(kind: StoreKind) throws {
        let directory = scratchDirectory("nested-send")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let iphone = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        iphone.transport.clear()
        let waiting = MessageRecord(
            id: "waiting",
            senderId: me.nodeId,
            recipientId: alice.nodeId,
            conversationId: alice.nodeId.string,
            body: "nested",
            sentAt: now,
            pendingKey: true
        )
        stores.messages.save(waiting)

        let outer = stores.transactor.atomically { () -> Int? in
            iphone.engine.flushPendingDirect(to: alice.nodeId)
            refusing.refusesRows = true
            stores.messages.insertIfAbsent(
                MessageRecord(id: "refused", senderId: me.nodeId, recipientId: nil, conversationId: "nearby", body: "x", sentAt: now))
            refusing.refusesRows = false
            return 1
        }
        #expect(outer == .failed)
        #expect(iphone.transport.written(.chat).isEmpty, "nothing reached the transport")
        #expect(stores.messages.message("waiting")?.pendingKey == true)
        #expect(!stores.custody.contains("waiting"))
        #expect(stores.ratchet.records(of: alice.nodeId).session == nil)
        #expect(iphone.engine.seals == RatchetSealCounts())

        iphone.engine.flushPendingDirect(to: alice.nodeId)
        #expect(try androidReads("waiting", from: iphone, android) == ("nested", 1))
        #expect(stores.messages.message("waiting")?.pendingKey == false)
    }

    /// A peer that advertises the ratchet with an identity key X25519 refuses, a low-order point, and no prekey: the facade
    /// cannot start a session, and the v1 fallback refuses the same key, so the unit is abandoned. The DM waits, as today's
    /// v1 send leaves it, with nothing on the air, nothing counted and no session, and the heal's next try sends nothing
    /// either. Kotlin throws out of `sendChat` here (`MeshManager.kt:1307`).
    @Test func aDMThatNeitherTheRatchetNorV1WillSealWaits() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let lowOrder = try #require(
            PublicKeyBundle(signingKey: alice.keys.bundle.signingKey, agreementKey: [UInt8](repeating: 0, count: 32)))
        fixture.stores.peers.upsert(
            PeerRecord(
                nodeId: lowOrder.nodeId,
                name: "",
                status: "",
                publicKey: lowOrder.encoded,
                capabilities: AndroidPeer.capabilities,
                updatedAt: 1
            )
        )
        _ = fixture.engine.drainEvents()

        let record = try #require(fixture.engine.sendDirectMessage("nowhere", to: lowOrder.nodeId))
        #expect(record.pendingKey && fixture.stores.messages.message(record.id)?.pendingKey == true)
        fixture.advance(MeshConfiguration().healMilliseconds)
        #expect(fixture.transport.written(.chat).isEmpty, "nothing on the air, before the heal or after")
        #expect(fixture.stores.messages.message(record.id)?.pendingKey == true)
        #expect(fixture.engine.seals == RatchetSealCounts())
        #expect(fixture.stores.ratchet.records(of: lowOrder.nodeId).session == nil)
        #expect(!fixture.engine.drainEvents().contains(.sent(messageId: record.id)))
    }

    /// With the switch on, the heal retries only DMs to a peer whose pinned profile carries `CAP_RATCHET`: one waiting for a
    /// peer pinned with no capabilities at all, from a build before they were sent, waits for its key's arrival as before.
    @Test func theHealRetriesOnlyDMsToARatchetPeer() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let waiting = MessageRecord(
            id: "waiting",
            senderId: me.nodeId,
            recipientId: alice.nodeId,
            conversationId: alice.nodeId.string,
            body: "old",
            sentAt: now,
            pendingKey: true
        )
        fixture.stores.messages.save(waiting)
        fixture.stores.peers.upsert(
            PeerRecord(nodeId: alice.nodeId, name: "", status: "", publicKey: alice.keys.bundle.encoded, capabilities: nil, updatedAt: 1))
        fixture.advance(MeshConfiguration().healMilliseconds)
        #expect(fixture.transport.written(.chat).isEmpty)
        #expect(fixture.stores.messages.message("waiting")?.pendingKey == true)
    }

    /// With the switch off, the heal leaves a waiting DM alone, as it always did: only its key's arrival sends it.
    @Test func withTheSwitchOffTheHealSendsNothing() throws {
        let fixture = EngineFixture(me)
        let record = try #require(fixture.engine.sendDirectMessage("later", to: alice.nodeId))
        fixture.stores.peers.upsert(
            PeerRecord(nodeId: alice.nodeId, name: "", status: "", publicKey: alice.keys.bundle.encoded, capabilities: 0x15F, updatedAt: 1))
        fixture.advance(MeshConfiguration().healMilliseconds)
        #expect(fixture.transport.written(.chat).isEmpty)
        #expect(fixture.stores.messages.message(record.id)?.pendingKey == true)
    }
}
