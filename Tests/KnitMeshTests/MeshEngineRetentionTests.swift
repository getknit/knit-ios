import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The engine's retention sweep (knit-ios #21, `MeshManager.sweepLocalStorage` at knit-next `e63f15f4`): at start and on
/// the 600 s sweep it trims the room and the message requests, never a thread a fetch or the screens take for accepted, a
/// group whose only known poster is blocked included; it trims nothing when its read fails in its unit or its write
/// fails; and a trimmed photo's want goes at once while its bytes go to the sweep of unnamed blobs.
@Suite struct MeshEngineRetentionTests {
    private let me = TestPeer(seed: 1)
    private let contact = TestPeer(seed: 2)
    private let verified = TestPeer(seed: 3)
    private let written = TestPeer(seed: 4)
    private let blocked = TestPeer(seed: 5)
    private let stranger = TestPeer(seed: 6)
    private let quiet = TestPeer(seed: 7)
    private let now = EngineFixture.start
    private let day: Int64 = 86_400_000
    private var sweep: Int64 { MeshConfiguration().sweepMilliseconds }

    /// `count` rows from `sender` in `conversation`, the newest at `newest`, one millisecond apart, ids `<tag>-<index>`.
    private func rows(_ count: Int, from sender: TestPeer, in conversation: String, tag: String, newest: Int64) -> [MessageRecord] {
        (0..<count).map { index in
            let sentAt = newest - Int64(count - 1 - index)
            let recipient = conversation == Conversations.nearby || Conversations.isGroup(conversation) ? nil : me.nodeId
            return MessageRecord(
                id: "\(tag)-\(index)",
                senderId: sender.nodeId,
                recipientId: recipient,
                conversationId: conversation,
                body: "hi",
                sentAt: sentAt,
                arrivedAt: sentAt
            )
        }
    }

    private func save(_ records: [MessageRecord], in stores: MeshStores) {
        for record in records {
            stores.messages.save(record)
        }
    }

    /// The ids held in `conversation`.
    private func held(_ conversation: String, in stores: MeshStores) -> Set<String> {
        Set(stores.messages.messages(in: conversation).map(\.id))
    }

    /// Every protected thread, each 60 rows and a week and a day old, and a request, a quiet request and the room to trim.
    private func history(_ fixture: EngineFixture) throws {
        let stores = fixture.stores
        let old = now - 8 * day
        for peer in [contact, verified, written, blocked] {
            try fixture.pin(peer)
        }
        fixture.engine.accept(contact.nodeId.string)
        fixture.engine.setVerified(verified.nodeId, true)
        fixture.engine.setVerified(blocked.nodeId, true)
        fixture.engine.block(blocked.nodeId)
        save(rows(60, from: contact, in: contact.nodeId.string, tag: "contact", newest: old), in: stores)
        save(rows(60, from: verified, in: verified.nodeId.string, tag: "verified", newest: old), in: stores)
        save(rows(59, from: written, in: written.nodeId.string, tag: "written", newest: old), in: stores)
        save(rows(1, from: me, in: written.nodeId.string, tag: "ours", newest: old), in: stores)
        save(rows(60, from: stranger, in: "g-known", tag: "known", newest: old), in: stores)
        save(rows(1, from: contact, in: "g-known", tag: "kc", newest: old), in: stores)
        save(rows(60, from: stranger, in: "g-blocked", tag: "blk", newest: old), in: stores)
        save(rows(1, from: blocked, in: "g-blocked", tag: "bb", newest: old), in: stores)
        save(rows(60, from: stranger, in: stranger.nodeId.string, tag: "req", newest: now - 1000), in: stores)
        save(rows(2, from: quiet, in: quiet.nodeId.string, tag: "quiet", newest: old), in: stores)
        save(rows(1, from: stranger, in: Conversations.nearby, tag: "aged", newest: now - 31 * day), in: stores)
        save(rows(1, from: stranger, in: Conversations.nearby, tag: "room", newest: now), in: stores)
    }

    /// The threads every pass must leave whole, and their row counts.
    private func expectProtectedWhole(_ stores: MeshStores, sourceLocation: SourceLocation = #_sourceLocation) {
        for (conversation, count) in [
            (contact.nodeId.string, 60), (verified.nodeId.string, 60), (written.nodeId.string, 60), ("g-known", 61), ("g-blocked", 61),
        ] {
            #expect(held(conversation, in: stores).count == count, "\(conversation) is protected", sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: StoreKind.allCases)
    func theSweepTrimsTheRoomAndTheRequestsAndNeverAProtectedThread(kind: StoreKind) throws {
        let directory = scratchDirectory("retention-sweep")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, _) = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let fixture = EngineFixture(me, stores: stores)
        try history(fixture)
        _ = fixture.engine.drainEvents()
        fixture.advance(sweep)

        expectProtectedWhole(stores)
        #expect(held(stranger.nodeId.string, in: stores) == Set((10..<60).map { "req-\($0)" }), "the request keeps its newest 50")
        #expect(held(quiet.nodeId.string, in: stores).isEmpty, "a week quiet, it goes whole")
        #expect(held(Conversations.nearby, in: stores) == ["room-0"])
        #expect((0..<10).allSatisfy { stores.messages.contains("req-\($0)") }, "a request a carrier still holds is remembered")
        #expect(!stores.messages.contains("quiet-0") && !stores.messages.contains("aged-0"), "nothing older is")
        let threads = [stranger.nodeId.string, quiet.nodeId.string, Conversations.nearby].sorted { first, second in
            first.utf8.lexicographicallyPrecedes(second.utf8)
        }
        #expect(fixture.engine.drainEvents() == [.trimmed(conversations: threads)])
        #expect(fixture.log.all.contains("info mesh retention trimmed 13 messages from 3 threads"))

        fixture.advance(sweep)
        #expect(fixture.engine.drainEvents().isEmpty, "a pass with nothing to trim says nothing")
    }

    @Test func theStartTrimsWhatAccumulatedWhileTheMeshWasDown() {
        let stores = MeshStores.inMemory()
        save(rows(1, from: stranger, in: Conversations.nearby, tag: "aged", newest: now - 31 * day), in: stores)
        let fixture = EngineFixture(me, stores: stores)
        #expect(stores.messages.messages(in: Conversations.nearby).isEmpty)
        #expect(fixture.engine.drainEvents() == [.trimmed(conversations: [Conversations.nearby])])
    }

    @Test(arguments: StoreKind.allCases)
    func aFailedReadOfTheAcceptedThreadsTrimsNothing(kind: StoreKind) throws {
        // Outside a unit the read answers no thread accepted, and every DM would read as a request.
        let directory = scratchDirectory("retention-unread")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingConversationReads(blobs: directory, failures: ReportedFailures().record)
        let fixture = EngineFixture(me, stores: stores)
        try history(fixture)
        _ = fixture.engine.drainEvents()
        refusing.failsReads = true
        fixture.advance(sweep)
        refusing.failsReads = false
        expectProtectedWhole(stores)
        #expect(held(stranger.nodeId.string, in: stores).count == 60 && held(Conversations.nearby, in: stores).count == 2)
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.log.all.contains("warning mesh retention skipped: a store failed"))

        fixture.advance(sweep)
        expectProtectedWhole(stores)
        #expect(held(stranger.nodeId.string, in: stores).count == 50, "the next pass that reads trims")
    }

    @Test func aFailedTrimRemovesNothingAndSaysNothing() throws {
        let directory = scratchDirectory("retention-refused")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try StoreKind.memory.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let fixture = EngineFixture(me, stores: stores)
        try history(fixture)
        _ = fixture.engine.drainEvents()
        refusing.refusesTrims = true
        fixture.advance(sweep)
        #expect(held(stranger.nodeId.string, in: stores).count == 60 && held(quiet.nodeId.string, in: stores).count == 2)
        #expect(fixture.engine.drainEvents().isEmpty)
    }

    // MARK: Photos

    @Test func aTrimmedPhotosWantGoesAtOnceAndItsBytesGoWithTheSweepOfUnnamedBlobs() {
        let fixture = EngineFixture(me)
        let stores = fixture.stores
        let wanted = Array("a picture nobody here holds".utf8)
        let kept = Array("a picture held for a stranger's post".utf8)
        var asked = rows(1, from: stranger, in: Conversations.nearby, tag: "asked", newest: now - 31 * day)[0]
        asked.attachment = MessageAttachment(hash: BlobHash(of: wanted), mime: "image/jpeg")
        var holding = rows(1, from: quiet, in: Conversations.nearby, tag: "holding", newest: now - 31 * day)[0]
        holding.attachment = MessageAttachment(hash: BlobHash(of: kept), mime: "image/jpeg")
        save([asked, holding], in: stores)
        stores.blobs.insert(kept, hash: BlobHash(of: kept), mime: "image/jpeg", storedAt: now - 15 * 60_000)
        fixture.engine.rewantMissingBlobs(sparing: [])
        #expect(fixture.engine.blobExchange.isWanted(BlobHash(of: wanted)), "each a stranger's newest room photo")
        #expect(fixture.engine.blobsTheRowsName().contains(BlobHash(of: kept)))

        fixture.advance(sweep)
        #expect(stores.messages.messages(in: Conversations.nearby).isEmpty)
        #expect(!fixture.engine.blobExchange.isWanted(BlobHash(of: wanted)), "its want went with its row")
        #expect(stores.blobs.contains(BlobHash(of: kept)), "younger than an echo's life, it waits for the sweep")
        #expect(!fixture.engine.blobsTheRowsName().contains(BlobHash(of: kept)), "named by nothing")
        #expect(fixture.engine.blobExchange.echoBudget.heldForOthers == Int64(kept.count), "so it counts toward the echo budget")

        fixture.advance(sweep)
        #expect(!stores.blobs.contains(BlobHash(of: kept)), "30 minutes stored, the sweep takes it")
        #expect(!fixture.engine.blobExchange.isWanted(BlobHash(of: wanted)), "and no re-offer wants it again")
    }
}
