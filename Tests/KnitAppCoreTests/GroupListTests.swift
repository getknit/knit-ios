import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Groups in the lists: their titles and status lines (`GroupNaming.kt`, `statusNoticeText`), and where a group sits,
/// in the chats or the requests (`ChatListAssembler.kt`, `ConversationTable.kt`), ADR 2026-09.n393.
@MainActor
@Suite struct GroupListTests {
    private let sam = AppRig.sam
    private let priya = AppRig.priya
    private let stranger = AppRig.stranger

    // MARK: Names

    @Test func anUnnamedGroupIsTitledAfterItsOtherMembers() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya")
        let directory = rig.session.directory
        let pair = await rig.group([sam], createdBy: sam)
        #expect(GroupNaming.title(of: pair, me: rig.me, directory: directory) == "Sam")
        let three = await rig.group([sam, priya], createdBy: sam)
        #expect(GroupNaming.title(of: three, me: rig.me, directory: directory) == "Sam & Priya", "in roster order, us left out")
        let four = await rig.group([sam, priya, stranger], createdBy: sam)
        let alias = rig.session.directory.label(for: stranger.nodeId).text
        #expect(GroupNaming.title(of: four, me: rig.me, directory: directory) == "Sam, Priya & \(alias)")
        var named = three
        named.name = "Hikers"
        #expect(GroupNaming.title(of: named, me: rig.me, directory: directory) == "Hikers", "a name wins")
        let alone = GroupRecord(id: "g-alone", createdBy: rig.me.string, createdAt: 1, roster: [GroupMember(nodeId: rig.me.string)])
        #expect(GroupNaming.title(of: alone, me: rig.me, directory: directory) == Copy.Groups.unnamed)
    }

    @Test func aStatusLineReadsInTheCatalogsWords() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        let directory = rig.session.directory
        func words(_ line: MessageRecord) -> String? {
            GroupNaming.notice(line, me: rig.me, directory: directory)
        }
        #expect(words(StatusNotices.groupCreated("g-1", by: rig.me, at: 1)) == Copy.Groups.createdByYou)
        #expect(words(StatusNotices.groupCreated("g-1", by: sam.nodeId, at: 1)) == Copy.Groups.created(by: "Sam"))
        #expect(words(StatusNotices.memberLeft("g-1", member: sam.nodeId, at: 1)) == Copy.Groups.left("Sam"))
        #expect(words(StatusNotices.memberRejoined("g-1", member: sam.nodeId, at: 1)) == Copy.Groups.rejoined("Sam"))
        #expect(
            words(StatusNotices.groupRenamed("g-1", by: sam.nodeId, to: "Hikers", at: 1)) == Copy.Groups.renamed(by: "Sam", to: "Hikers"))
        #expect(words(StatusNotices.memberLeft("g-1", member: rig.me, at: 1)) == Copy.Groups.left(Copy.Common.you))
        var future = StatusNotices.memberLeft("g-1", member: sam.nodeId, at: 1)
        future.kind = MessageKind(rawValue: 42)
        #expect(words(future) == nil, "a kind with no words is left out")
    }

    @Test func aRequestNamesWhoStartedTheGroup() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya")
        let directory = rig.session.directory
        let group = await rig.group([priya, sam], createdBy: sam)
        #expect(GroupNaming.starter(of: group, me: rig.me, directory: directory) == "Sam")
        var unknown = group
        unknown.createdBy = "nobody here"
        #expect(GroupNaming.starter(of: unknown, me: rig.me, directory: directory) == "Priya", "else the first other member")
        let alone = GroupRecord(id: "g-alone", createdBy: rig.me.string, createdAt: 1, roster: [GroupMember(nodeId: rig.me.string)])
        #expect(GroupNaming.starter(of: alone, me: rig.me, directory: directory) == Copy.Groups.unnamed)
    }

    // MARK: Where a group sits

    @Test func aStrangersGroupWaitsAsARequestEvenWithNothingButStatusLines() async {
        let rig = AppRig()
        let group = await rig.group([stranger, sam], createdBy: stranger)
        let threads = rig.session.threads()
        #expect(threads.requests.map(\.id) == [group.id])
        #expect(threads.requests.first?.head == nil && threads.requests.first?.lastActivity == group.createdAt)
        let list = ChatListModel(session: rig.session).state
        #expect(list.rows.map(\.id) == [Conversations.nearby])
        #expect(list.requestCount == 1)
        let rows = RequestsModel(session: rig.session).rows
        #expect(rows.map(\.isGroup) == [true] && rows.first?.preview == nil)
    }

    @Test func aGroupSomeoneWeKnowWritesInIsAChat() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam", verified: true)
        let group = await rig.group([sam, stranger], createdBy: stranger)
        #expect(rig.session.threads().isRequest(group.id), "being on the roster is not enough")
        await rig.receive("Hi all", from: sam.nodeId, in: group)
        let list = ChatListModel(session: rig.session).state
        let row = list.rows.first { $0.id == group.id }
        #expect(row?.isGroup == true && row?.isRoom == false)
        #expect(row?.preview == Copy.ChatList.preview(speaker: "Sam", body: "Hi all"))
        #expect(list.requestCount == 0)
    }

    @Test func anEmptyGroupWeMadeSortsByWhenItWasMade() async throws {
        let rig = AppRig()
        rig.stores.conversations.accept(sam.nodeId.string)
        await rig.receive("Old news", from: sam.nodeId, to: rig.me, sentAt: 100)
        let group = try #require(await rig.session.createGroup(with: [sam.nodeId, priya.nodeId]))
        await rig.receive("Fresh", from: priya.nodeId, to: rig.me, sentAt: rig.mesh.clock + 1)
        rig.stores.conversations.accept(priya.nodeId.string)
        await rig.session.handle(.groupChanged(group.id))
        let rows = ChatListModel(session: rig.session).state.rows
        #expect(rows.map(\.id) == [Conversations.nearby, priya.nodeId.string, group.id, sam.nodeId.string])
        let made = rows.first { $0.id == group.id }
        #expect(made?.preview == nil && made?.lastMessageAt == rig.mesh.clock, "our own created line accepts it")
    }

    @Test func aGroupWeLeftIsNowhere() async throws {
        let rig = AppRig()
        let group = try #require(await rig.session.createGroup(with: [sam.nodeId, priya.nodeId]))
        #expect(await rig.session.leaveGroup(group.id))
        #expect(ChatListModel(session: rig.session).state.rows.map(\.id) == [Conversations.nearby])
        #expect(rig.session.threads().requests.isEmpty)
        #expect(rig.session.threads().group(group.id) == nil)
    }

    @Test func aGroupRequestRowNamesTheGroupAndItsSpeaker() async {
        let rig = AppRig()
        let group = await rig.group([stranger, priya], createdBy: stranger)
        await rig.receive("Hello?", from: stranger.nodeId, in: group, sentAt: 2000)
        await rig.receive("Hi there", from: sam.nodeId, to: rig.me, sentAt: 1000)
        let rows = RequestsModel(session: rig.session).rows
        #expect(rows.map(\.id) == [group.id, sam.nodeId.string], "newest first")
        let alias = rig.session.directory.label(for: stranger.nodeId).text
        #expect(rows.first?.title == GroupNaming.title(of: group, me: rig.me, directory: rig.session.directory))
        #expect(rows.first?.preview == Copy.ChatList.preview(speaker: alias, body: "Hello?"))
        #expect(rows.last?.preview == "Hi there" && rows.last?.isGroup == false)
    }
}
