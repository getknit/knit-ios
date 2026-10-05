import Foundation
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Deleting on the screens (ADR 2026-10.u7cq): a message from its bubble, a chat from its row, a request from the
/// inbox, and clearing the room, as knit-next's `ChatViewModelTest`, `ChatListViewModelTest` and
/// `MessageRequestsViewModelTest` pin them. Every delete goes through the mesh, which sends nothing.
@MainActor
@Suite struct DeleteTests {
    private let sam = AppRig.sam
    private let priya = AppRig.priya
    private let stranger = AppRig.stranger

    /// 2026-10-04 at 12:00 UTC, in milliseconds.
    private static let noon: Int64 = 1_791_115_200_000
    private static let minute: Int64 = 60_000

    /// A calendar on UTC, so a day's edge is the same wherever the test runs.
    private static let calendar: Calendar = {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? utc.timeZone
        return utc
    }()

    // MARK: A message

    @Test func deletingAMessageTakesItsBubbleAndItsNeighboursCluster() async throws {
        // Two minutes apart, each joins the next; four minutes apart, they no longer do (ADR 2026-10.5waw).
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        rig.stores.conversations.accept(sam.nodeId.string)
        for (index, body) in ["One", "Two", "Three"].enumerated() {
            await rig.receive(body, from: sam.nodeId, to: rig.me, id: body, sentAt: Self.noon + Int64(index) * 2 * Self.minute)
        }
        let thread = ChatModel(conversationId: sam.nodeId.string, session: rig.session)
        #expect(MessageClusters.places(thread.state.messages, calendar: Self.calendar).map(\.joinsNext) == [true, true, false])
        let middle = try #require(thread.state.messages.first { $0.id == "Two" })
        await thread.delete(middle)
        #expect(rig.mesh.calls.deleted == ["message Two"])
        #expect(thread.state.messages.map(\.id) == ["One", "Three"])
        #expect(MessageClusters.places(thread.state.messages, calendar: Self.calendar).map(\.joinsNext) == [false, false])
        #expect(rig.notifier.withdrawn.isEmpty, "the thread is open, so its notification already went")
    }

    @Test func aStatusLineHasNoDelete() async throws {
        let rig = AppRig()
        let group = await rig.group([sam, priya], createdBy: AppRig.me)
        let thread = ChatModel(conversationId: group.id, session: rig.session)
        let created = try #require(thread.state.messages.first)
        #expect(created.notice != nil)
        await thread.delete(created)
        #expect(rig.mesh.calls.deleted.isEmpty)
        #expect(thread.state.messages.map(\.id) == [created.id])
    }

    @Test func deletingOurOnlyMessageLeavesTheChatAccepted() async throws {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.session.send("Hi Sam", in: sam.nodeId.string)
        let thread = ChatModel(conversationId: sam.nodeId.string, session: rig.session)
        let mine = try #require(thread.state.messages.first)
        await thread.delete(mine)
        await rig.receive("Hi back", from: sam.nodeId, to: rig.me)
        #expect(ChatListModel(session: rig.session).state.rows.map(\.id) == [Conversations.nearby, sam.nodeId.string])
        #expect(RequestsModel(session: rig.session).rows.isEmpty, "not a request")
    }

    // MARK: A chat

    @Test func aDeletedDmLeavesTheListAndItsNextMessageBringsItBackAccepted() async throws {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.session.send("Hi Sam", in: sam.nodeId.string)
        await rig.receive("Hi", from: sam.nodeId, to: rig.me, sentAt: 2000)
        let list = ChatListModel(session: rig.session)
        let row = try #require(list.state.rows.last)
        #expect(row.id == sam.nodeId.string)
        await list.delete(row)
        #expect(rig.mesh.calls.deleted == ["chat \(sam.nodeId)"])
        #expect(list.state.rows.map(\.id) == [Conversations.nearby])
        #expect(rig.notifier.withdrawn == [sam.nodeId.string, NotificationPolicy.requestsThread])
        #expect(ChatModel(conversationId: sam.nodeId.string, session: rig.session).state.messages.isEmpty)
        await rig.receive("Still there?", from: sam.nodeId, to: rig.me, sentAt: 3000)
        #expect(list.state.rows.map(\.id) == [Conversations.nearby, sam.nodeId.string])
        #expect(list.state.requestCount == 0)
    }

    @Test func aDeletedGroupLeavesTheListUntilItsNextMessageAndWeStayInIt() async throws {
        let rig = AppRig()
        let group = await rig.group([sam, priya], name: "Hikers", createdBy: AppRig.me)
        await rig.receive("Trail at 9?", from: sam.nodeId, in: group)
        let list = ChatListModel(session: rig.session)
        let row = try #require(list.state.rows.first { $0.id == group.id })
        await list.delete(row)
        #expect(list.state.rows.map(\.id) == [Conversations.nearby])
        #expect(rig.mesh.calls.groups.isEmpty, "nothing left the group")
        #expect(GroupInfoModel(groupId: group.id, session: rig.session).state.exists)
        #expect(ChatModel(conversationId: group.id, session: rig.session).state.messages.isEmpty)
        await rig.receive("Anyone?", from: priya.nodeId, in: group, sentAt: 2000)
        #expect(list.state.rows.map(\.id) == [Conversations.nearby, group.id])
        #expect(list.state.requestCount == 0, "it comes back accepted")
    }

    @Test func clearingTheRoomKeepsItsRow() async throws {
        let rig = AppRig()
        await rig.receive("Anyone near the lake?", from: sam.nodeId)
        let list = ChatListModel(session: rig.session)
        let room = try #require(list.state.rows.first)
        #expect(room.isRoom && room.preview != nil)
        await list.delete(room)
        #expect(rig.mesh.calls.deleted == ["chat \(Conversations.nearby)"])
        #expect(list.state.rows.map(\.id) == [Conversations.nearby])
        #expect(list.state.rows.first?.preview == nil)
        #expect(rig.stores.conversations.acceptedConversations().isEmpty, "the room needs no accepting")
    }

    // MARK: A request

    @Test func aDeletedRequestGoesWithItsNotificationAndComesBackAsANewOne() async {
        let rig = AppRig()
        await rig.receive("Who's this?", from: stranger.nodeId, to: rig.me)
        await rig.receive("Hello?", from: priya.nodeId, to: rig.me)
        let requests = RequestsModel(session: rig.session)
        await requests.delete(stranger.nodeId.string)
        #expect(requests.rows.map(\.id) == [priya.nodeId.string])
        #expect(rig.notifier.withdrawn == [stranger.nodeId.string], "a request still waits, so its notification stays")
        await requests.delete(priya.nodeId.string)
        #expect(requests.rows.isEmpty)
        #expect(rig.notifier.withdrawn.suffix(2) == [priya.nodeId.string, NotificationPolicy.requestsThread])
        #expect(rig.stores.conversations.acceptedConversations().isEmpty, "a delete accepts nothing")
        await rig.receive("Me again", from: stranger.nodeId, to: rig.me, sentAt: 2000)
        #expect(requests.rows.map(\.id) == [stranger.nodeId.string])
    }

    @Test func aDeletedGroupRequestWaitsForItsNextMessage() async {
        let rig = AppRig()
        let theirs = await rig.group([stranger, sam], createdBy: stranger)
        let requests = RequestsModel(session: rig.session)
        #expect(requests.rows.map(\.id) == [theirs.id])
        await requests.delete(theirs.id)
        #expect(requests.rows.isEmpty)
        #expect(ChatListModel(session: rig.session).state.rows.map(\.id) == [Conversations.nearby])
        await rig.receive("Join us", from: stranger.nodeId, in: theirs, sentAt: 2000)
        #expect(requests.rows.map(\.id) == [theirs.id], "still a request")
    }
}
