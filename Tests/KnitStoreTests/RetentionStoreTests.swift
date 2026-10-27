import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// What the stores read and write for retention (knit-ios #21), against every store: the rows weighed, and a trim that
/// remembers, with no photo, each message a carrier could still re-serve.
@Suite struct RetentionStoreTests {
    private static let kinds = RepositoryKind.allCases

    private let bob = fixtureNodeId(2)
    private let now: Int64 = 1_756_200_000_000
    private let maybePhoto = BlobHash(String(repeating: "e", count: 64))

    /// Bob's message `id` in `conversation`, sent at `sentAt`, carrying `photo` when asked.
    private func message(_ id: String, in conversation: String = "g-1", sentAt: Int64, carrying photo: BlobHash? = nil) -> MessageRecord {
        MessageRecord(
            id: id,
            senderId: bob,
            recipientId: nil,
            conversationId: conversation,
            body: "hi",
            sentAt: sentAt,
            attachment: photo.map { MessageAttachment(hash: $0) }
        )
    }

    @Test(arguments: kinds)
    func theRowsWeighedAreTheNamedThreadsOnly(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("m", sentAt: 5))
        store.save(StatusNotices.groupCreated("g-1", by: bob, at: 1))
        store.save(message("room", in: Conversations.nearby, sentAt: 7))
        store.save(message("other", in: "g-2", sentAt: 9))
        let rows = store.retentionRows(in: ["g-1", Conversations.nearby, "g-absent"])
        #expect(
            Set(rows.map(\.id)) == ["m", StatusNotices.groupCreated("g-1", by: bob, at: 1).id, "room"])
        #expect(rows.contains(RetentionRow(id: "m", conversationId: "g-1", senderId: bob, sentAt: 5)))
        #expect(rows.contains { $0.kind == .groupCreated && $0.sentAt == 1 })
        #expect(store.retentionRows(in: []).isEmpty)
    }

    @Test(arguments: kinds)
    func aTrimRemembersWhatACarrierCouldReserveWithNoPhotoAndNothingOlder(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let photo = try #require(maybePhoto)
        let ttl = CustodyLimits().ttlMilliseconds
        store.save(message("fresh", sentAt: now - 1000, carrying: photo))
        store.save(message("stale", sentAt: now - 2 * ttl - WireProtocol.maxFutureSkewMilliseconds))
        let notice = StatusNotices.groupCreated("g-1", by: bob, at: now)
        store.save(notice)
        store.save(message("kept", sentAt: now))
        let removed = store.trimMessages(["fresh", "stale", notice.id, "absent"], at: now)
        #expect(Set(removed.map(\.id)) == ["fresh", "stale", notice.id], "what went, for the engine to release")
        #expect(removed.first { $0.id == "fresh" }?.attachment?.hash == photo)
        #expect(store.messages(in: "g-1").map(\.id) == ["kept"])
        #expect(store.contains("fresh") && !store.insertIfAbsent(message("fresh", sentAt: now - 1000)), "it cannot come back as new")
        #expect(!store.contains("stale") && !store.contains(notice.id), "no carrier holds it, and a status line's id is ours")
        #expect(store.deletedAttachments().isEmpty, "the tombstone names no photo")
        let lifetime = now - 1000 + 2 * ttl + WireProtocol.maxFutureSkewMilliseconds
        store.pruneDeleted(before: lifetime)
        #expect(store.contains("fresh"), "two TTLs past its sentAt, for a carrier a TTL behind")
        store.pruneDeleted(before: lifetime + 1)
        #expect(!store.contains("fresh"), "and then forgotten")
    }

    @Test(arguments: kinds)
    func aRoomPostIsRememberedOnlyWithinTwiceTheRoomsSixHours(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let edge = now - 2 * CustodyLimits().roomChatTTLMilliseconds - WireProtocol.maxFutureSkewMilliseconds
        store.save(message("inside", in: Conversations.nearby, sentAt: edge + 1))
        store.save(message("outside", in: Conversations.nearby, sentAt: edge))
        store.trimMessages(["inside", "outside"], at: now)
        #expect(store.contains("inside") && !store.contains("outside"))
        let room = CustodyLimits().roomChatTTLMilliseconds + WireProtocol.maxFutureSkewMilliseconds
        store.pruneDeleted(before: now + room)
        #expect(store.contains("inside"), "remembered for the room's six hours from the trim")
        store.pruneDeleted(before: now + room + 1)
        #expect(!store.contains("inside"), "and no longer")
    }

    @Test(arguments: kinds)
    func aTrimOverADeletesTombstoneKeepsItsPhotoAndTheLaterExpiry(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let photo = try #require(maybePhoto)
        store.save(message("m", sentAt: now, carrying: photo))
        store.deleteMessage("m", at: now + 50)
        store.save(message("m", sentAt: now, carrying: photo))
        #expect(store.trimMessages(["m"], at: now).map(\.id) == ["m"])
        #expect(store.deletedAttachments() == [DeletedAttachment(id: "m", hash: photo)], "the delete's photo stays named")
        store.pruneDeleted(before: DeletedMessages.expiry(sentAt: now, deletedAt: now + 50))
        #expect(store.contains("m"), "the delete's later expiry stands")
    }

    @Test(arguments: kinds)
    func aTrimOfManyRowsGoesInBatchesAndIdsKeepTheirBytes(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let ids = (0..<1203).map { "m-\($0)" }
        for (index, id) in ids.enumerated() {
            store.save(message(id, in: "t-\(index % 600)", sentAt: now))
        }
        store.save(message("\u{212A}", sentAt: now))
        store.save(message("K", sentAt: now))
        #expect(store.retentionRows(in: Set((0..<600).map { "t-\($0)" })).count == 1203)
        #expect(store.trimMessages(ids + ["K"], at: now).count == 1204)
        #expect(store.retentionRows(in: ["g-1"]).map(\.id) == ["\u{212A}"], "the Kelvin sign is not K")
        #expect(store.conversationIds() == ["g-1"])
        #expect(store.trimMessages([], at: now).isEmpty)
    }
}
