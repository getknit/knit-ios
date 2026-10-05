import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The group store (`GroupDao` and `GroupRepository` in knit-next), run against every implementation, and the
/// status lines group threads hold (`StatusNotices.kt`).
@Suite struct GroupStoreTests {
    private static let kinds = RepositoryKind.allCases

    private let alice = fixtureNodeId(1).string
    private let bob = fixtureNodeId(2).string
    private let carol = fixtureNodeId(3).string

    private func group(_ id: String = "g-1", roster: [GroupMember]? = nil) -> GroupRecord {
        GroupRecord(
            id: id,
            name: "Hikers",
            createdBy: alice,
            createdAt: 10,
            nameUpdatedAt: 12,
            photoHash: "ph1",
            photoUpdatedAt: 11,
            roster: roster ?? [
                GroupMember(nodeId: bob),
                GroupMember(nodeId: alice, rejoinedAt: 9),
                GroupMember(nodeId: carol, departed: true, leftAt: 14),
            ]
        )
    }

    @Test(arguments: kinds)
    func aGroupKeepsEveryFieldAndItsRosterInOrder(kind: RepositoryKind) throws {
        let store = try kind.make().groups
        #expect(store.group("g-1") == nil)
        let saved = group()
        store.save(saved)
        #expect(store.group("g-1") == saved)
        let bare = GroupRecord(id: "g-2", createdBy: bob, createdAt: 1, roster: [GroupMember(nodeId: "not a node id")])
        store.save(bare)
        #expect(store.group("g-2") == bare, "nil fields read back as nil, and a member's id is kept whatever it is")
    }

    @Test(arguments: kinds)
    func aSaveReplacesTheRowAndItsWholeRoster(kind: RepositoryKind) throws {
        let store = try kind.make().groups
        store.save(group())
        var later = group(roster: [GroupMember(nodeId: carol), GroupMember(nodeId: bob, departed: true, leftAt: 20)])
        later.hasLeft = true
        later.name = ""
        store.save(later)
        #expect(store.group("g-1") == later)
        #expect(store.groups() == [later])
    }

    @Test(arguments: kinds)
    func groupsListByTheBytesOfTheirIds(kind: RepositoryKind) throws {
        let store = try kind.make().groups
        store.save(group("g-b"))
        store.save(group("g-\u{212A}"))
        store.save(group("g-K"))
        store.save(group("g-a"))
        #expect(store.groups().map(\.id) == ["g-K", "g-a", "g-b", "g-\u{212A}"], "the Kelvin sign is a group of its own")
    }

    @Test func aRecordSaysWhatOurFramesCarry() {
        let held = group()
        #expect(held.members == [bob, alice])
        #expect(held.departed == [carol])
        #expect(held.member(carol)?.leftAt == 14)
        #expect(held.member("\u{212A}") == nil)
        let carried = GroupInfo(
            id: "g-1",
            name: "Hikers",
            members: [bob, alice],
            createdBy: alice,
            photoHash: "ph1",
            photoUpdatedAt: 11,
            departed: [carol]
        )
        #expect(held.info == carried)
        let unnamed = GroupRecord(id: "g-2", createdBy: alice, createdAt: 1, roster: [GroupMember(nodeId: alice)])
        #expect(unnamed.info == GroupInfo(id: "g-2", members: [alice], createdBy: alice), "no name, no photo and nobody gone")
    }

    /// `StatusNotices.kt`: each line's id is fixed by its event, and its sender is whom it is about.
    @Test func statusLinesUseKnitNextsIdsAndKinds() {
        let subject = fixtureNodeId(2)
        let created = StatusNotices.groupCreated("g-1", by: subject, at: 5)
        #expect(created.id == "created:g-1" && created.kind == .groupCreated && created.sentAt == 5)
        #expect(created.senderId == subject && created.conversationId == "g-1" && created.recipientId == nil)
        let left = StatusNotices.memberLeft("g-1", member: subject, at: 6)
        #expect(left.id == "leave:g-1:\(subject)" && left.kind == .memberLeft)
        let back = StatusNotices.memberRejoined("g-1", member: subject, at: 7)
        #expect(back.id == "rejoin:g-1:\(subject)" && back.kind == .memberRejoined)
        let renamed = StatusNotices.groupRenamed("g-1", by: subject, to: "Hikers", at: 8)
        #expect(renamed.id == "grename:g-1:8" && renamed.kind == .groupRenamed && renamed.body == "Hikers")
        #expect([created, left, back, renamed].allSatisfy { $0.kind.isNotice && !$0.delivered && !$0.pendingKey })
        #expect(!MessageKind.message.isNotice)
    }
}

/// What groups add to the message store and to `Conversations`, run against every implementation.
@Suite struct GroupThreadTests {
    private static let kinds = RepositoryKind.allCases

    private let alice = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)

    private func groupMessage(_ id: String, from sender: NodeId, sentAt: Int64 = 1) -> MessageRecord {
        MessageRecord(id: id, senderId: sender, recipientId: nil, conversationId: "g-1", body: "hi", sentAt: sentAt)
    }

    private func message(_ id: String, from sender: NodeId, to recipient: NodeId, pendingKey: Bool = false) -> MessageRecord {
        MessageRecord(
            id: id,
            senderId: sender,
            recipientId: recipient,
            conversationId: Conversations.id(sender: sender, recipient: recipient, me: alice),
            body: "hi",
            sentAt: 1,
            pendingKey: pendingKey
        )
    }

    @Test func aGroupIsNamedByItsPrefix() {
        #expect(Conversations.isGroup("g-0fcb434512afea55af84f0a5"))
        #expect(!Conversations.isGroup(Conversations.nearby))
        #expect(!Conversations.isGroup(bob.string))
    }

    /// `Conversations.isAccepted`'s group arm: a known sender accepts a group, its roster alone does not.
    @Test func aGroupIsAcceptedByAKnownSenderNotByItsRoster() {
        let carol = fixtureNodeId(3)
        func accepted(senders: Set<NodeId>, accepted: Set<String> = [], verified: Set<NodeId> = [], authored: Set<String> = []) -> Bool {
            Conversations.isAccepted("g-1", accepted: accepted, verified: verified, authored: authored, groupSenders: senders)
        }
        #expect(!accepted(senders: [carol]), "a stranger's group is a request")
        #expect(accepted(senders: [carol], accepted: [carol.string]), "a sender whose DM we accepted")
        #expect(accepted(senders: [carol], verified: [carol]), "a sender we verified")
        #expect(accepted(senders: [carol], authored: [carol.string]), "a sender we wrote to")
        #expect(accepted(senders: [], accepted: ["g-1"]), "the group itself, accepted")
        #expect(accepted(senders: [], authored: ["g-1"]), "a group we wrote in")
        #expect(!accepted(senders: [], verified: [carol]), "someone we verified who has not written in it")
    }

    @Test(arguments: kinds)
    func aStatusLineKeepsItsKindAndIsNeverAThreadsHead(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        store.save(groupMessage("g1", from: bob, sentAt: 2))
        store.save(StatusNotices.memberLeft("g-1", member: bob, at: 5))
        store.save(StatusNotices.groupCreated("g-2", by: bob, at: 9))
        #expect(store.message("leave:g-1:\(bob)")?.kind == .memberLeft)
        #expect(store.threadHeads().map(\.id) == ["g1"], "a thread of nothing but status lines has no head")
        #expect(store.messages(in: "g-1").map(\.id) == ["g1", "leave:g-1:\(bob)"])
        var future = groupMessage("future", from: bob, sentAt: 3)
        future.kind = MessageKind(rawValue: 42)
        store.save(future)
        #expect(store.message("future")?.kind.isNotice == true, "a kind from a newer build reads as a status line")
    }

    @Test(arguments: kinds)
    func sendersAreTheAuthorsOfOrdinaryMessagesOnly(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        let carol = fixtureNodeId(3)
        store.save(groupMessage("g1", from: bob))
        store.save(groupMessage("g2", from: bob))
        store.save(StatusNotices.groupCreated("g-1", by: carol, at: 1))
        store.save(message("dm", from: carol, to: alice))
        #expect(store.senders(in: "g-1") == [bob])
        #expect(store.senders(in: "g-none").isEmpty)
    }

    @Test(arguments: kinds)
    func aStatusLineAboutUsCountsAsAuthored(kind: RepositoryKind) throws {
        // MessageDao.conversationsIAuthoredIn has no kind filter: the creator's own "created" line accepts its group.
        let store = try kind.make().messages
        store.save(StatusNotices.groupCreated("g-1", by: alice, at: 1))
        #expect(store.conversations(authoredBy: alice) == ["g-1"])
    }

    @Test(arguments: kinds)
    func pendingGroupMessagesListOldestFirst(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        var late = groupMessage("late", from: alice, sentAt: 9)
        late.pendingKey = true
        var early = groupMessage("early", from: alice, sentAt: 2)
        early.pendingKey = true
        store.save(late)
        store.save(early)
        store.save(groupMessage("sent", from: alice, sentAt: 1))
        store.save(message("dm", from: alice, to: bob, pendingKey: true))
        #expect(store.pendingKey(in: "g-1").map(\.id) == ["early", "late"])
        #expect(store.pendingKey(to: bob).map(\.id) == ["dm"], "a group message waits on no one recipient")
    }

    @Test(arguments: kinds)
    func deletingAThreadTakesItsStatusLinesAndLeavesTheRest(kind: RepositoryKind) throws {
        let store = try kind.make().messages
        var mine = groupMessage("g1", from: bob)
        mine.conversationId = "g-K"
        store.save(mine)
        store.save(StatusNotices.groupCreated("g-K", by: bob, at: 1))
        var kelvin = groupMessage("kelvin", from: bob)
        kelvin.conversationId = "g-\u{212A}"
        store.save(kelvin)
        store.save(message("dm", from: bob, to: alice))
        let removed = store.deleteMessages(in: "g-K", at: 5)
        #expect(removed.map(\.id) == ["g1", "created:g-K"], "what went, in reading order")
        #expect(store.message("g1") == nil && store.message("created:g-K") == nil)
        #expect(store.contains("g1"), "a deleted message's id is remembered")
        #expect(!store.contains("created:g-K"), "a status line's is not")
        #expect(store.message("kelvin") != nil, "a thread whose id differs in its bytes stays")
        #expect(store.message("dm") != nil)
    }
}
