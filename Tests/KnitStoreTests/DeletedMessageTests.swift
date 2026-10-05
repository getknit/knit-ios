import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// Deleting a message, and the ids remembered so a re-served frame cannot bring it back (ADR 2026-10.u7cq), against
/// every store.
@Suite struct DeletedMessageTests {
    private static let kinds = RepositoryKind.allCases

    private let alice = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)

    /// Bob's message `id` in `conversation`, sent at `sentAt`.
    private func message(_ id: String, in conversation: String = "g-1", sentAt: Int64 = 1) -> MessageRecord {
        MessageRecord(id: id, senderId: bob, recipientId: nil, conversationId: conversation, body: "hi", sentAt: sentAt)
    }

    /// When an id deleted at `deletedAt` from a message sent at `sentAt` may be forgotten.
    private func expiry(sentAt: Int64 = 1, deletedAt: Int64) -> Int64 {
        DeletedMessages.expiry(sentAt: sentAt, deletedAt: deletedAt)
    }

    @Test func anIdIsRememberedPastTheLastInstantAnyCarrierHoldsItsFrame() {
        let ttl = CustodyLimits().ttlMilliseconds
        let skew = WireProtocol.maxFutureSkewMilliseconds
        #expect(DeletedMessages.expiry(sentAt: 1, deletedAt: 5) == 5 + ttl + skew, "from the delete when it is later")
        #expect(DeletedMessages.expiry(sentAt: 9, deletedAt: 5) == 9 + ttl + skew, "from a sentAt ahead of our clock")
        #expect(DeletedMessages.expiry(sentAt: .max, deletedAt: 5) < 0, "a hostile sentAt wraps rather than traps")
    }

    @Test(arguments: kinds)
    func deletingOneMessageLeavesItsNeighbours(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("a", sentAt: 1))
        store.save(message("b", sentAt: 2))
        store.save(message("c", sentAt: 3))
        let removed = store.deleteMessage("b", at: 10)
        #expect(removed == message("b", sentAt: 2), "the delete answers what it removed")
        #expect(store.messages(in: "g-1").map(\.id) == ["a", "c"])
        #expect(store.message("b") == nil)
        #expect(store.threadHeads().map(\.id) == ["c"])
    }

    @Test(arguments: kinds)
    func aDeletedIdIsRememberedSoItsFrameCannotBringItBack(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("m"))
        store.deleteMessage("m", at: 10)
        #expect(store.contains("m"), "the delivery gates read a deleted id as held")
        #expect(!store.insertIfAbsent(message("m")), "a re-served frame stores nothing")
        #expect(store.message("m") == nil && store.messages(in: "g-1").isEmpty)
        #expect(store.conversationIds().isEmpty)
    }

    @Test(arguments: kinds)
    func aStatusLineIsNeverRemembered(kind: RepositoryKind) throws {
        // A status line's id is our own and deterministic: the next change to the group must be able to write it again.
        let store = try kind.make().messages
        let created = StatusNotices.groupCreated("g-1", by: bob, at: 1)
        store.save(created)
        #expect(store.deleteMessage(created.id, at: 10) == created)
        #expect(!store.contains(created.id))
        #expect(store.insertIfAbsent(created))
    }

    @Test(arguments: kinds)
    func aDeletedIdIsForgottenOnceNoCarrierCanHoldItsFrame(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("m"))
        store.deleteMessage("m", at: 10)
        store.pruneDeleted(before: expiry(deletedAt: 10))
        #expect(store.contains("m"), "still remembered at its last instant")
        store.pruneDeleted(before: expiry(deletedAt: 10) + 1)
        #expect(!store.contains("m"))
        #expect(store.insertIfAbsent(message("m")), "a frame nobody could still carry")
    }

    @Test(arguments: kinds)
    func aSecondDeleteKeepsTheLaterExpiry(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("m"))
        store.deleteMessage("m", at: 20)
        store.save(message("m"))
        store.deleteMessage("m", at: 10)
        store.pruneDeleted(before: expiry(deletedAt: 20))
        #expect(store.contains("m"))
    }

    @Test(arguments: kinds)
    func idsThatDifferInTheirBytesStayApart(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("\u{212A}"))
        store.save(message("K"))
        store.deleteMessage("\u{212A}", at: 10)
        #expect(store.message("K") != nil)
        store.deleteMessage("K", at: 10)
        store.pruneDeleted(before: 0)
        #expect(store.contains("\u{212A}") && store.contains("K"))
        #expect(!store.contains("k"))
    }

    @Test(arguments: kinds)
    func deletingWhatIsNotHeldChangesNothing(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        #expect(store.deleteMessage("m", at: 10) == nil)
        #expect(!store.contains("m"))
        #expect(store.deleteMessages(in: "g-1", at: 10).isEmpty)
    }

    @Test(arguments: kinds)
    func aDeletedMessageTakesNoVerdictAndWaitsForNone(kind: RepositoryKind) throws {
        // The app screens a message off the mesh's actor, so a delete can land before its verdict does.
        let store = try kind.make().messages
        var waiting = message("m")
        waiting.moderation = .waiting
        store.save(waiting)
        store.deleteMessage("m", at: 10)
        #expect(store.waitingForModeration().isEmpty)
        #expect(!store.setModeration("m", to: .flagged))
        #expect(store.message("m") == nil)
    }

    @Test(arguments: kinds)
    func deletingAThreadRemembersItsMessagesAndTakesItsPhotos(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let photo = try #require(BlobHash(String(repeating: "c", count: 64)))
        var carrying = message("p", sentAt: 2)
        carrying.attachment = MessageAttachment(hash: photo)
        store.save(message("m", sentAt: 1))
        store.save(carrying)
        store.save(message("other", in: Conversations.nearby))
        let removed = store.deleteMessages(in: "g-1", at: 10)
        #expect(removed.map(\.id) == ["m", "p"])
        #expect(removed.last?.attachment?.hash == photo, "what went names its photo, for the engine to release")
        #expect(store.contains("m") && store.contains("p"))
        #expect(store.attachmentHashes().isEmpty)
        #expect(store.conversationIds() == [Conversations.nearby])
    }

    @Test(arguments: kinds)
    func aDeletedPhotoIsNamedByItsFrameUntilItsIdIsForgotten(kind: RepositoryKind) throws {
        // Its bytes stay while custody carries the frame, so the store keeps which frame named which photo.
        let store = try kind.make().messages
        let photo = try #require(BlobHash(String(repeating: "d", count: 64)))
        var carrying = message("p")
        carrying.attachment = MessageAttachment(hash: photo)
        store.save(carrying)
        store.save(message("plain"))
        store.save(StatusNotices.groupCreated("g-1", by: bob, at: 1))
        #expect(store.deletedAttachments().isEmpty)
        store.deleteMessages(in: "g-1", at: 10)
        #expect(store.deletedAttachments() == [DeletedAttachment(id: "p", hash: photo)])
        store.pruneDeleted(before: expiry(deletedAt: 10) + 1)
        #expect(store.deletedAttachments().isEmpty)
    }

    @Test(arguments: kinds)
    func everyThreadWithARowIsNamedStatusLinesIncluded(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        #expect(store.conversationIds().isEmpty)
        store.save(StatusNotices.groupCreated("g-1", by: alice, at: 1))
        store.save(message("m", in: bob.string))
        #expect(store.conversationIds() == ["g-1", bob.string])
        #expect(store.threadHeads().map(\.conversationId) == [bob.string], "a thread of status lines has no head")
    }
}
