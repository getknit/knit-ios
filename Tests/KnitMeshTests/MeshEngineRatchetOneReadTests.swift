import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// With the switch on, one read of the peer's pinned row decides how a DM is sealed (ADR 2026-10.5sk9, phase P5b; the P5b
/// crypto review's first finding). A read that fails, as `SQLPeerStore.peer` answers `nil` for one, leaves the DM waiting:
/// a second read for the v1 arm could find the row and send a ratchet peer v1, uncounted and never upgraded, where Kotlin's
/// read throws and nothing is sealed (`MeshManager.kt:1290`, `PeerRepository.kt:138`). The heal, or the next flush, then
/// sends it with the ratchet. Each runs over the memory stores and the database.
@Suite struct MeshEngineRatchetOneReadTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private var now: Int64 { EngineFixture.start }

    /// An engine with the switch on over stores whose peer reads fail when told to, with Android pinned.
    private struct Rig {
        let iphone: EngineFixture
        let android: AndroidPeer
        let peers: FailingPeerReads
    }

    /// The rig over stores of `kind`.
    private func rig(_ kind: StoreKind, in directory: URL) throws -> Rig {
        let (stores, _) = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let peers = FailingPeerReads(stores.peers)
        let iphone = try EngineFixture.ratcheting(me, stores: stores.replacing(peers: peers))
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        iphone.transport.clear()
        _ = iphone.engine.drainEvents()
        return Rig(iphone: iphone, android: android, peers: peers)
    }

    /// What Android reads of the one DM frame the engine sent under `id`.
    private func androidReads(_ id: String, from iphone: EngineFixture, _ android: AndroidPeer) throws -> String? {
        let frames = iphone.transport.written(.chat).filter { $0.envelope.id == id }
        #expect(frames.count == 1, "sent once")
        let frame = try #require(frames.first)
        #expect(try ChatContent(decoding: frame.envelope.payload).enc?.version == EncEnvelope.Version.compactRatchet)
        let bytes = try #require(plaintext(try android.open(frame, from: me, now: iphone.clock.wallMilliseconds())))
        return MessageContentV2.decode(bytes)?.body
    }

    @Test(arguments: StoreKind.allCases)
    func aSendWhosePeerReadFailsWaitsAndTheHealSendsItWithTheRatchet(kind: StoreKind) throws {
        let directory = scratchDirectory("one-read-send")
        defer { try? FileManager.default.removeItem(at: directory) }
        let made = try rig(kind, in: directory)
        let iphone = made.iphone
        let android = made.android
        let peers = made.peers

        peers.failsReads = 1
        let record = try #require(iphone.engine.sendDirectMessage("one read", to: alice.nodeId))
        #expect(peers.failsReads == 0, "the send read the row once, and that read failed")
        #expect(record.pendingKey && iphone.stores.messages.message(record.id)?.pendingKey == true, "saved, waiting")
        #expect(iphone.transport.written(.chat).isEmpty, "nothing on the air, v1 included")
        #expect(iphone.stores.custody.frame(record.id, now: iphone.clock.wallMilliseconds()) == nil, "nor in custody")
        #expect(iphone.engine.seals == RatchetSealCounts())

        iphone.advance(MeshConfiguration().healMilliseconds)
        #expect(try androidReads(record.id, from: iphone, android) == "one read")
        #expect(iphone.engine.seals == RatchetSealCounts(dmSealedV2: 1, dmSealedV3: 1), "with the ratchet, no fallback")
        #expect(iphone.stores.messages.message(record.id)?.pendingKey == false)
        #expect(iphone.engine.drainEvents().contains(.sent(messageId: record.id)))
    }

    @Test(arguments: StoreKind.allCases)
    func aFlushWhosePeerReadFailsLeavesEveryDMWaiting(kind: StoreKind) throws {
        let directory = scratchDirectory("one-read-flush")
        defer { try? FileManager.default.removeItem(at: directory) }
        let made = try rig(kind, in: directory)
        let iphone = made.iphone
        let android = made.android
        let peers = made.peers
        let ids = ["first", "second"]
        for (offset, id) in ids.enumerated() {
            let row = MessageRecord(
                id: id,
                senderId: me.nodeId,
                recipientId: alice.nodeId,
                conversationId: alice.nodeId.string,
                body: id,
                sentAt: now + Int64(offset),
                pendingKey: true
            )
            iphone.stores.messages.save(row)
        }

        peers.failsReads = 1
        iphone.engine.flushPendingDirect(to: alice.nodeId)
        #expect(peers.failsReads == 0, "one read for the whole flush, and it failed")
        #expect(iphone.transport.written(.chat).isEmpty, "nothing on the air, v1 included")
        #expect(ids.allSatisfy { iphone.stores.messages.message($0)?.pendingKey == true }, "every one still waiting")
        #expect(ids.allSatisfy { iphone.stores.custody.frame($0, now: iphone.clock.wallMilliseconds()) == nil }, "none in custody")
        #expect(iphone.engine.seals == RatchetSealCounts())

        iphone.engine.flushPendingDirect(to: alice.nodeId)
        #expect(try ids.map { try androidReads($0, from: iphone, android) } == ids)
        #expect(iphone.engine.seals == RatchetSealCounts(dmSealedV2: 2, dmSealedV3: 2), "with the ratchet, no fallback")
        #expect(ids.allSatisfy { iphone.stores.messages.message($0)?.pendingKey == false })
    }
}
