import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The peer, message, conversation and own-profile stores.
@Suite struct RepositoryTests {
    private let alice = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)

    private func message(
        _ id: String,
        from sender: NodeId,
        to recipient: NodeId?,
        sentAt: Int64 = 1,
        pendingKey: Bool = false
    ) -> MessageRecord {
        MessageRecord(
            id: id,
            senderId: sender,
            recipientId: recipient,
            conversationId: Conversations.id(sender: sender, recipient: recipient, me: alice),
            body: "hi",
            sentAt: sentAt,
            pendingKey: pendingKey
        )
    }

    @Test func peersUpsertAndReportTheVerifiedOnes() {
        let store = MemoryPeerStore()
        #expect(store.peer(bob) == nil)
        store.upsert(PeerRecord(nodeId: bob, name: "Bob", status: "", publicKey: "key", updatedAt: 1))
        store.upsert(PeerRecord(nodeId: alice, name: "Alice", status: "", publicKey: "key", updatedAt: 1, verified: true))
        #expect(store.peer(bob)?.name == "Bob")
        #expect(store.verifiedNodeIds() == [alice])
        #expect(store.allPeers().map(\.nodeId) == [alice, bob].sorted())
    }

    @Test func aMessageIsStoredOnceAndReadInOrder() {
        let store = MemoryMessageStore()
        #expect(store.insertIfAbsent(message("m2", from: bob, to: alice, sentAt: 5)))
        #expect(!store.insertIfAbsent(message("m2", from: bob, to: alice, sentAt: 9)), "a re-served frame says nothing new")
        store.insertIfAbsent(message("m1", from: bob, to: alice, sentAt: 5))
        store.insertIfAbsent(message("m0", from: alice, to: bob, sentAt: 1))
        #expect(store.message("m2")?.sentAt == 5)
        #expect(store.contains("m1"))
        #expect(store.messages(in: bob.string).map(\.id) == ["m0", "m2", "m1"], "ties keep the order they were stored")
        #expect(store.message("missing") == nil)
    }

    @Test func saveReplacesAndDeliveryMarksOnce() {
        let store = MemoryMessageStore()
        store.save(message("m1", from: alice, to: bob))
        #expect(store.markDelivered("m1"))
        #expect(!store.markDelivered("m1"), "already delivered")
        #expect(!store.markDelivered("missing"))
        var edited = message("m1", from: alice, to: bob)
        edited.body = "edited"
        store.save(edited)
        #expect(store.message("m1")?.body == "edited")
        #expect(store.messages(in: bob.string).count == 1)
    }

    @Test func pendingKeyDMsListOldestFirstUntilCleared() {
        let store = MemoryMessageStore()
        store.save(message("late", from: alice, to: bob, sentAt: 9, pendingKey: true))
        store.save(message("early", from: alice, to: bob, sentAt: 2, pendingKey: true))
        store.save(message("sent", from: alice, to: bob, sentAt: 1))
        store.save(message("other", from: alice, to: fixtureNodeId(3), sentAt: 1, pendingKey: true))
        #expect(store.pendingKey(to: bob).map(\.id) == ["early", "late"])
        store.clearPendingKey("early")
        #expect(store.pendingKey(to: bob).map(\.id) == ["late"])
    }

    @Test func authoredConversationsNameTheThreadsWeWroteIn() {
        let store = MemoryMessageStore()
        store.save(message("room", from: alice, to: nil))
        store.save(message("dm", from: alice, to: bob))
        store.save(message("in", from: fixtureNodeId(3), to: alice))
        #expect(store.conversations(authoredBy: alice) == [Conversations.nearby, bob.string])
    }

    @Test func messageIdsCompareByTheirBytes() {
        let store = MemoryMessageStore()
        store.insertIfAbsent(message("idK", from: bob, to: alice))
        #expect(store.insertIfAbsent(message("id\u{212A}", from: bob, to: alice)), "the Kelvin sign is not a K on Android")
        #expect(store.messages(in: bob.string).count == 2)
    }

    @Test func conversationIdsFollowTheOtherParty() {
        #expect(Conversations.id(sender: bob, recipient: nil, me: alice) == Conversations.nearby)
        #expect(Conversations.id(sender: alice, recipient: bob, me: alice) == bob.string)
        #expect(Conversations.id(sender: bob, recipient: alice, me: alice) == bob.string)
    }

    @Test func aConversationIsAcceptedByTheRoomAnAcceptAVerifyOrAReply() {
        let carol = fixtureNodeId(3).string
        func accepted(_ id: String, accepted: Set<String> = [], verified: Set<NodeId> = [], authored: Set<String> = []) -> Bool {
            Conversations.isAccepted(id, accepted: accepted, verified: verified, authored: authored)
        }
        #expect(accepted(Conversations.nearby))
        #expect(!accepted(carol), "a stranger's first DM is a request")
        #expect(accepted(carol, accepted: [carol]))
        #expect(accepted(carol, verified: [fixtureNodeId(3)]))
        #expect(accepted(carol, authored: [carol]))
        #expect(!accepted("not-a-node-id", verified: [fixtureNodeId(3)]))
    }

    @Test func acceptedConversationsAccumulate() {
        let store = MemoryConversationStore()
        #expect(store.acceptedConversations().isEmpty)
        store.accept(bob.string)
        store.accept(bob.string)
        #expect(store.acceptedConversations() == [bob.string])
    }

    @Test func theOwnProfileStartsUnpublishedAndSaves() {
        let store = MemoryOwnProfileStore()
        #expect(store.load() == OwnProfile())
        #expect(store.load().publishedAt == 0 && store.load().version == 0)
        store.save(OwnProfile(name: "Alice", status: "here", openToChat: true, version: 7, publishedAt: 9))
        #expect(store.load().name == "Alice")
        #expect(MemoryOwnProfileStore(OwnProfile(name: "Seeded")).load().name == "Seeded")
    }
}
