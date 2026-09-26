import KnitStore
import KnitStoreSQL
import KnitTestSupport
import KnitWire
import Testing

/// Every implementation of the peer, message, conversation and own-profile stores. Each runs the whole
/// ``RepositoryTests`` suite.
enum RepositoryKind: CaseIterable, Sendable, CustomTestStringConvertible {
    case memory
    case sql

    /// One set of stores, sharing one database where the kind has one.
    struct Stores {
        var peers: any PeerStore
        var messages: any MessageStore
        var conversations: any ConversationStore
        var ownProfile: any OwnProfileStore
    }

    var testDescription: String {
        switch self {
        case .memory:
            "memory"
        case .sql:
            "sql"
        }
    }

    func make() throws -> Stores {
        switch self {
        case .memory:
            return Stores(
                peers: MemoryPeerStore(),
                messages: MemoryMessageStore(),
                conversations: MemoryConversationStore(),
                ownProfile: MemoryOwnProfileStore()
            )
        case .sql:
            let database = try KnitDatabase.inMemory(failures: recordFailure)
            return Stores(
                peers: SQLPeerStore(database),
                messages: SQLMessageStore(database),
                conversations: SQLConversationStore(database),
                ownProfile: SQLOwnProfileStore(database)
            )
        }
    }
}

/// The peer, message, conversation and own-profile stores, run against every implementation.
@Suite struct RepositoryTests {
    private static let kinds = RepositoryKind.allCases

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

    @Test(arguments: kinds)
    func peersUpsertAndReportTheVerifiedOnes(kind: RepositoryKind) throws {
        let store = try kind.make().peers
        #expect(store.peer(bob) == nil)
        store.upsert(PeerRecord(nodeId: bob, name: "Bob", status: "", publicKey: "key", updatedAt: 1))
        store.upsert(PeerRecord(nodeId: alice, name: "Alice", status: "", publicKey: "key", updatedAt: 1, verified: true))
        #expect(store.peer(bob)?.name == "Bob")
        #expect(store.verifiedNodeIds() == [alice])
        #expect(store.allPeers().map(\.nodeId) == [alice, bob].sorted())
    }

    @Test(arguments: kinds)
    func aPeerKeepsEveryFieldAndAnUpsertReplacesThem(kind: RepositoryKind) throws {
        let store = try kind.make().peers
        let full = PeerRecord(
            nodeId: bob,
            name: "Bob",
            status: "around",
            publicKey: "key",
            deviceTag: "tag",
            protocolVersion: 3,
            capabilities: 0x9,
            updatedAt: 7,
            verified: true,
            openToChat: true
        )
        store.upsert(full)
        #expect(store.peer(bob) == full)
        let bare = PeerRecord(nodeId: bob, name: "", status: "", publicKey: "key", updatedAt: 8)
        store.upsert(bare)
        #expect(store.peer(bob) == bare, "nil fields read back as nil, not as the old values")
        #expect(store.allPeers() == [bare])
    }

    @Test(arguments: kinds)
    func aMessageIsStoredOnceAndReadInOrder(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        #expect(store.insertIfAbsent(message("m2", from: bob, to: alice, sentAt: 5)))
        #expect(!store.insertIfAbsent(message("m2", from: bob, to: alice, sentAt: 9)), "a re-served frame says nothing new")
        store.insertIfAbsent(message("m1", from: bob, to: alice, sentAt: 5))
        store.insertIfAbsent(message("m0", from: alice, to: bob, sentAt: 1))
        #expect(store.message("m2")?.sentAt == 5)
        #expect(store.contains("m1"))
        #expect(!store.contains("missing"))
        #expect(store.messages(in: bob.string).map(\.id) == ["m0", "m2", "m1"], "ties keep the order they were stored")
        #expect(store.message("missing") == nil)
    }

    @Test(arguments: kinds)
    func aMessageKeepsEveryField(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        var inbound = message("in", from: bob, to: alice, sentAt: 4)
        inbound.arrivedAt = 6
        inbound.body = "multi\nline \u{1F9F6} and a NUL \u{0} inside"
        store.save(inbound)
        let room = message("room", from: alice, to: nil, sentAt: 5)
        store.save(room)
        #expect(store.message("in") == inbound)
        #expect(store.message("room") == room, "a room post has no recipient and no arrival")
    }

    @Test(arguments: kinds)
    func saveReplacesAndDeliveryMarksOnce(kind: RepositoryKind) throws {
        let store = try kind.make().messages
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

    @Test(arguments: kinds)
    func aSaveOverAnExistingMessageKeepsItsPlaceAmongTies(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("first", from: alice, to: bob, sentAt: 3))
        store.save(message("second", from: alice, to: bob, sentAt: 3))
        store.save(message("first", from: alice, to: bob, sentAt: 3, pendingKey: true))
        #expect(store.messages(in: bob.string).map(\.id) == ["first", "second"])
    }

    @Test(arguments: kinds)
    func pendingKeyDMsListOldestFirstUntilCleared(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("late", from: alice, to: bob, sentAt: 9, pendingKey: true))
        store.save(message("early", from: alice, to: bob, sentAt: 2, pendingKey: true))
        store.save(message("sent", from: alice, to: bob, sentAt: 1))
        store.save(message("other", from: alice, to: fixtureNodeId(3), sentAt: 1, pendingKey: true))
        #expect(store.pendingKey(to: bob).map(\.id) == ["early", "late"])
        store.clearPendingKey("early")
        #expect(store.pendingKey(to: bob).map(\.id) == ["late"])
    }

    @Test(arguments: kinds)
    func authoredConversationsNameTheThreadsWeWroteIn(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(message("room", from: alice, to: nil))
        store.save(message("dm", from: alice, to: bob))
        store.save(message("in", from: fixtureNodeId(3), to: alice))
        #expect(store.conversations(authoredBy: alice) == [Conversations.nearby, bob.string])
    }

    @Test(arguments: kinds)
    func eachThreadsHeadIsItsNewestMessageAndTheNewestThreadLeads(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        #expect(store.threadHeads().isEmpty)
        store.save(message("room-old", from: alice, to: nil, sentAt: 1))
        store.save(message("room-new", from: bob, to: nil, sentAt: 8))
        store.save(message("dm-first", from: bob, to: alice, sentAt: 5))
        store.save(message("dm-tie", from: alice, to: bob, sentAt: 5))
        store.save(message("other", from: fixtureNodeId(3), to: alice, sentAt: 2))
        #expect(store.threadHeads().map(\.id) == ["room-new", "dm-tie", "other"], "a tie goes to the one stored last")
        store.save(message("dm-first", from: bob, to: alice, sentAt: 5, pendingKey: true))
        #expect(store.threadHeads().map(\.id) == ["room-new", "dm-tie", "other"], "a save keeps its place among ties")
    }

    @Test(arguments: kinds)
    func threadsWhoseIdsDifferInTheirBytesHaveTheirOwnHeads(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        var kelvin = message("k", from: bob, to: nil)
        kelvin.conversationId = "\u{212A}"
        var plain = message("p", from: bob, to: nil, sentAt: 2)
        plain.conversationId = "K"
        store.save(kelvin)
        store.save(plain)
        #expect(store.threadHeads().map(\.id) == ["p", "k"])
    }

    @Test(arguments: kinds)
    func messageIdsCompareByTheirBytes(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.insertIfAbsent(message("idK", from: bob, to: alice))
        #expect(store.insertIfAbsent(message("id\u{212A}", from: bob, to: alice)), "the Kelvin sign is not a K on Android")
        #expect(store.insertIfAbsent(message("idK\u{0}x", from: bob, to: alice)), "nor is an id its own prefix")
        #expect(store.messages(in: bob.string).count == 3)
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

    @Test(arguments: kinds)
    func acceptedConversationsAccumulate(kind: RepositoryKind) throws {
        let store = try kind.make().conversations
        #expect(store.acceptedConversations().isEmpty)
        store.accept(bob.string)
        store.accept(bob.string)
        store.accept(Conversations.nearby)
        #expect(store.acceptedConversations() == [bob.string, Conversations.nearby])
    }

    @Test(arguments: kinds)
    func theOwnProfileStartsUnpublishedAndSaves(kind: RepositoryKind) throws {
        let store = try kind.make().ownProfile
        #expect(store.load() == OwnProfile())
        #expect(store.load().publishedAt == 0 && store.load().version == 0)
        let saved = OwnProfile(name: "Alice", status: "here", openToChat: true, version: 7, publishedAt: 9)
        store.save(saved)
        #expect(store.load() == saved)
        store.save(OwnProfile(name: "Al", version: 8, publishedAt: 10))
        #expect(store.load() == OwnProfile(name: "Al", version: 8, publishedAt: 10), "one profile, replaced")
    }

    @Test func theMemoryOwnProfileStoreStartsFromWhatItIsGiven() {
        #expect(MemoryOwnProfileStore(OwnProfile(name: "Seeded")).load().name == "Seeded")
    }
}
