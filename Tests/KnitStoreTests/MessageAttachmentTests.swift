import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// What a message carries, kept by every message store (schema v5 for the SQL one, ADR 2026-10.nh55).
@Suite struct MessageAttachmentTests {
    private static let kinds = RepositoryKind.allCases

    private let alice = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)

    private func message(_ id: String, in conversation: String, carrying attachment: MessageAttachment?) -> MessageRecord {
        MessageRecord(
            id: id, senderId: bob, recipientId: nil, conversationId: conversation, body: "", sentAt: 1, attachment: attachment)
    }

    /// A hash of one digit, `seed`, repeated.
    private func hash(_ seed: Int) -> BlobHash {
        BlobHash(String(repeating: String(seed % 10), count: 64)) ?? .empty
    }

    @Test(arguments: kinds)
    func aMessageKeepsWhatItCarries(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let room = message("room", in: Conversations.nearby, carrying: MessageAttachment(hash: hash(1), mime: "image/jpeg"))
        let sealed = message(
            "dm", in: bob.string, carrying: MessageAttachment(hash: hash(2), mime: "image/png", key: "a2V5IGJ5dGVz\u{0}"))
        let file = message(
            "file",
            in: bob.string,
            carrying: MessageAttachment(hash: hash(3), mime: "application/pdf", key: "aw==", name: "plan.pdf", size: 4096)
        )
        let plain = message("plain", in: bob.string, carrying: nil)
        for record in [room, sealed, file, plain] {
            store.save(record)
        }
        #expect(store.message("room") == room)
        #expect(store.message("dm") == sealed)
        #expect(store.message("file") == file)
        #expect(store.message("plain")?.attachment == nil)
        #expect(store.messages(in: bob.string).compactMap(\.attachment) == [sealed.attachment, file.attachment].compactMap(\.self))
    }

    /// Every write keeps the attachment: a column left out of a write would blank it the next time the row moves.
    @Test(arguments: kinds)
    func everyWriteKeepsTheAttachment(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        var ours = message("ours", in: bob.string, carrying: MessageAttachment(hash: hash(4), mime: "image/jpeg", key: "aw=="))
        ours.senderId = alice
        ours.recipientId = bob
        ours.pendingKey = true
        store.save(ours)
        store.clearPendingKey("ours")
        store.markDelivered("ours")
        #expect(store.message("ours")?.attachment == ours.attachment)
        ours.body = "a caption added"
        store.save(ours)
        #expect(store.message("ours")?.attachment == ours.attachment)
        #expect(!store.insertIfAbsent(message("ours", in: bob.string, carrying: nil)))
        #expect(store.message("ours")?.attachment == ours.attachment, "a re-served frame changes nothing")
    }

    @Test(arguments: kinds)
    func theStoreNamesTheBlobsItsMessagesCarry(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        #expect(store.attachmentHashes().isEmpty)
        store.save(message("a", in: Conversations.nearby, carrying: MessageAttachment(hash: hash(5))))
        store.save(message("b", in: "g-group", carrying: MessageAttachment(hash: hash(6))))
        store.save(message("c", in: "g-group", carrying: MessageAttachment(hash: hash(5))))
        store.save(message("d", in: "g-group", carrying: nil))
        #expect(store.attachmentHashes() == [hash(5), hash(6)])
        store.deleteMessages(in: "g-group", at: 0)
        #expect(store.attachmentHashes() == [hash(5)], "a thread that goes takes its photos' names with it")
    }

    /// Android's `attachmentsNeedingFetch`: the sender of the earliest message carrying each blob, by `sentAt` and then
    /// by id, so a re-armed fetch asks that author first (knit-next ADR 2026-10.f7gg).
    @Test(arguments: kinds)
    func theEarliestMessageCarryingABlobNamesItsSender(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let carol = fixtureNodeId(3)
        var late = message("a-late", in: Conversations.nearby, carrying: MessageAttachment(hash: hash(7)))
        late.sentAt = 9
        var early = message("z-early", in: "g-group", carrying: MessageAttachment(hash: hash(7)))
        early.senderId = alice
        early.sentAt = 2
        var tied = message("b-tied", in: Conversations.nearby, carrying: MessageAttachment(hash: hash(8)))
        tied.senderId = carol
        tied.sentAt = 4
        var tiedFirst = message("a-tied", in: Conversations.nearby, carrying: MessageAttachment(hash: hash(8)))
        tiedFirst.sentAt = 4
        for record in [late, early, tied, tiedFirst, message("plain", in: bob.string, carrying: nil)] {
            store.save(record)
        }
        #expect(store.attachmentSenders(among: [hash(7), hash(8), hash(9)]) == [hash(7): alice, hash(8): bob])
        #expect(store.attachmentSenders(among: [hash(8)]) == [hash(8): bob])
        #expect(store.attachmentSenders(among: []).isEmpty)
    }
}
