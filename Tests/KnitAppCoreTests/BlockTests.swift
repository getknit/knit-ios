import Foundation
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Blocking on the screens (ADR 2026-10.5wgg): what a block hides, where it is offered, and what an unblock brings
/// back, as knit-next's `ChatListViewModelTest`, `ChatViewModelTest`, `MessageRequestsViewModelTest`,
/// `ContactsViewModelTest`, `ProfileDetailsViewModelTest` and `BlockedUsersViewModelTest` pin them.
@MainActor
@Suite struct BlockTests {
    private let sam = AppRig.sam
    private let priya = AppRig.priya
    private let stranger = AppRig.stranger

    @Test func aBlockHidesTheirDMAndWhatTheyWroteUntilTheUnblock() async {
        // `blockedPeersDmThreadIsDropped` and `blockedSendersRowsAreFilteredOut`: nothing is deleted.
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        rig.stores.conversations.accept(sam.nodeId.string)
        await rig.receive("In the room", from: sam.nodeId, sentAt: 300)
        await rig.receive("Just for you", from: sam.nodeId, to: rig.me, sentAt: 100)
        await rig.session.send("Mine", in: sam.nodeId.string)
        let list = ChatListModel(session: rig.session)
        #expect(list.state.rows.map(\.id) == [Conversations.nearby, sam.nodeId.string])

        await PeerProfileModel(nodeId: sam.nodeId, session: rig.session).setBlocked(true)
        #expect(rig.mesh.calls.blocked == ["block \(sam.nodeId)"])
        #expect(list.state.rows.map(\.id) == [Conversations.nearby], "their DM leaves the list, ours in it too")
        #expect(list.state.rows.first?.preview == nil, "their room post leaves the room's preview")
        let thread = ChatModel(conversationId: sam.nodeId.string, session: rig.session)
        #expect(thread.state.isBlocked)
        #expect(thread.state.messages.map(\.body) == ["Mine"])
        thread.draft = "Can I still write?"
        #expect(!thread.canSend, "Unblock takes the composer's place")
        #expect(ChatModel(conversationId: Conversations.nearby, session: rig.session).state.messages.isEmpty)

        await thread.unblock()
        #expect(!thread.state.isBlocked && thread.canSend)
        #expect(thread.state.messages.map(\.body) == ["Just for you", "Mine"], "what they wrote before shows again")
        #expect(list.state.rows.map(\.id) == [Conversations.nearby, sam.nodeId.string])
        #expect(list.state.rows.first?.preview == "Sam: In the room")
    }

    @Test func blockingAStrangersRequestRemovesItAndItsNotification() async {
        // `aBlockedSenderIsNotShownAsARequest` and `request_blockPath_removesFromInbox`.
        let rig = AppRig()
        await rig.receive("Who's this?", from: stranger.nodeId, to: rig.me)
        await rig.receive("Hello?", from: priya.nodeId, to: rig.me)
        let requests = RequestsModel(session: rig.session)
        #expect(Set(requests.rows.map(\.id)) == [stranger.nodeId.string, priya.nodeId.string])
        await requests.block(stranger.nodeId.string)
        #expect(requests.rows.map(\.id) == [priya.nodeId.string])
        #expect(rig.notifier.withdrawn == [stranger.nodeId.string], "a request is still waiting, so its notification stays")
        await ChatModel(conversationId: priya.nodeId.string, session: rig.session).block()
        #expect(requests.rows.isEmpty)
        #expect(rig.notifier.withdrawn.suffix(2) == [priya.nodeId.string, NotificationPolicy.requestsThread])
        #expect(ChatListModel(session: rig.session).state.requestCount == 0)
    }

    @Test func aBlockedThreadIsNeverARequestBar() async {
        let rig = AppRig()
        await rig.receive("Who's this?", from: stranger.nodeId, to: rig.me)
        let thread = ChatModel(conversationId: stranger.nodeId.string, session: rig.session)
        #expect(thread.state.isRequest)
        await thread.block()
        #expect(!thread.state.isRequest && thread.state.isBlocked)
    }

    @Test func aGroupRequestHasNobodyToBlock() async {
        let rig = AppRig()
        let theirs = await rig.group([stranger, sam], createdBy: stranger)
        await RequestsModel(session: rig.session).block(theirs.id)
        await ChatModel(conversationId: theirs.id, session: rig.session).block()
        await ChatModel(conversationId: Conversations.nearby, session: rig.session).unblock()
        #expect(rig.mesh.calls.blocked.isEmpty)
    }

    @Test func aBlockedMembersMessagesLeaveAGroupButTheyStayInIt() async {
        // `observeNewestPerConversation skips blocked senders`; nothing under knit-next's `ui/group/` reads the block.
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya")
        let group = await rig.group([sam, priya], createdBy: priya)
        rig.stores.conversations.accept(group.id)
        await rig.receive("Tent's up", from: priya.nodeId, in: group, sentAt: 600)
        await rig.receive("Bring snacks", from: sam.nodeId, in: group, sentAt: 700)
        await rig.session.block(sam.nodeId)
        let row = ChatListModel(session: rig.session).state.rows.first { $0.id == group.id }
        #expect(row?.preview == "Priya: Tent's up")
        let thread = ChatModel(conversationId: group.id, session: rig.session).state
        #expect(!thread.messages.contains { $0.body == "Bring snacks" })
        #expect(thread.messages.contains { $0.body == "Tent's up" })
        #expect(thread.memberCount == 3, "Sam stays on the roster")
    }

    @Test func aGroupKnownOnlyThroughSomeoneBlockedIsARequestAgain() async {
        // `observeGroupSenders` leaves blocked senders out of the group-accept rule.
        let rig = AppRig()
        await rig.pin(sam, name: "Sam", verified: true)
        let theirs = await rig.group([stranger, sam], createdBy: stranger)
        await rig.receive("Hi", from: sam.nodeId, in: theirs)
        #expect(!rig.session.threads().isRequest(theirs.id))
        await rig.session.block(sam.nodeId)
        #expect(rig.session.threads().isRequest(theirs.id))
    }

    @Test func blockedPeopleAreNobodysContactsUntilTheUnblock() async {
        // `ContactsViewModelTest.blockedContactsAreExcluded`.
        let rig = AppRig()
        await rig.pin(sam, name: "Sam", verified: true)
        await rig.pin(priya, name: "Priya", verified: true)
        await rig.session.block(sam.nodeId)
        #expect(NewMessageModel(session: rig.session).candidates.map(\.id) == [priya.nodeId])
        await rig.session.unblock(sam.nodeId)
        #expect(NewMessageModel(session: rig.session).candidates.map(\.id) == [priya.nodeId, sam.nodeId])
    }

    @Test func theProfileSaysWhoIsBlockedAndNeverBlocksUs() async {
        // `stateReflectsProfilePresenceBlockAndKeyState`.
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        let profile = PeerProfileModel(nodeId: sam.nodeId, session: rig.session)
        #expect(!profile.state.isBlocked)
        await profile.setBlocked(true)
        #expect(profile.state.isBlocked)
        await profile.setBlocked(false)
        #expect(!profile.state.isBlocked)
        await PeerProfileModel(nodeId: rig.me, session: rig.session).setBlocked(true)
        #expect(rig.mesh.calls.blocked == ["block \(sam.nodeId)", "unblock \(sam.nodeId)"], "never ourselves")
    }

    @Test func theBlockedListNamesEveryoneByNameAndUnblocks() async {
        // `BlockedUsersViewModelTest`: sorted by name, and someone never pinned shows under their alias.
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya")
        let blocked = BlockedModel(session: rig.session)
        #expect(blocked.rows.isEmpty)
        for person in [sam, priya, stranger] {
            await rig.session.block(person.nodeId)
        }
        let alias = rig.session.directory.label(for: stranger.nodeId).text
        let expected = [("Priya", priya.nodeId), ("Sam", sam.nodeId), (alias, stranger.nodeId)]
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        #expect(blocked.rows.map(\.id) == expected.map(\.1))
        #expect(blocked.rows.map(\.title) == expected.map(\.0))
        await blocked.unblock(priya.nodeId)
        #expect(!blocked.rows.map(\.id).contains(priya.nodeId))
        #expect(rig.mesh.calls.blocked.last == "unblock \(priya.nodeId)")
    }

    @Test func aBlockTakesTheTagTheirProfileCarried() async {
        // `blockUsesTheCapturedDeviceTagSoItSticksAcrossAKeyReset`.
        let rig = AppRig()
        var record = sam.record(name: "Sam")
        record.deviceTag = "0011223344556677"
        rig.stores.peers.upsert(record)
        await rig.session.block(sam.nodeId)
        #expect(rig.stores.blocks.isBlocked(deviceTag: "0011223344556677"))
        await rig.session.unblock(sam.nodeId)
        #expect(!rig.stores.blocks.isBlocked(deviceTag: "0011223344556677"))
    }
}
