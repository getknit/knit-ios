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
}
