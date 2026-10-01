import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// The group screens' models: the thread, group info and the new-group picker (`ChatViewModel`,
/// `GroupDetailsViewModel` and `ContactsViewModel` in knit-next), and a group's notification, ADR 2026-09.n393.
@MainActor
@Suite struct GroupScreenTests {
    private let sam = AppRig.sam
    private let priya = AppRig.priya
    private let stranger = AppRig.stranger

    // MARK: The thread

    @Test func aGroupThreadNamesEachSpeakerAndShowsItsStatusLines() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam", verified: true)
        let group = await rig.group([sam, priya], createdBy: sam)
        await rig.receive("Who's in?", from: sam.nodeId, in: group, sentAt: 1000)
        await rig.receive("Me", from: rig.me, in: group, sentAt: 1001)
        let state = ChatModel(conversationId: group.id, session: rig.session).state
        #expect(state.kind == .group && state.isGroup && !state.isRoom && state.peer == nil)
        #expect(state.title == GroupNaming.title(of: group, me: rig.me, directory: rig.session.directory))
        #expect(state.messages.map(\.notice) == [Copy.Groups.created(by: "Sam"), nil, nil])
        #expect(state.messages.map(\.authorLabel) == [nil, "Sam", nil], "others are named, we are not")
        #expect(state.messages.last?.status == .sent)
        #expect(state.memberCount == 3 && !state.nobodyElse && state.exists && !state.isRequest)
    }

    @Test func aStrangersGroupThreadWaitsForAccept() async {
        let rig = AppRig()
        let group = await rig.group([stranger, sam], createdBy: stranger)
        let model = ChatModel(conversationId: group.id, session: rig.session)
        let alias = rig.session.directory.label(for: stranger.nodeId).text
        #expect(model.state.isRequest, "a group of nothing but status lines waits too")
        #expect(model.state.requestTitle == Copy.Groups.requestTitle(alias))
        #expect(model.state.requestBody == Copy.Groups.requestBody)
        await model.accept()
        #expect(!model.state.isRequest)
    }

    @Test func aGroupNobodyElseIsLeftInTakesNoMessage() async {
        let rig = AppRig()
        let group = await rig.group([], createdBy: sam, departed: [sam])
        let model = ChatModel(conversationId: group.id, session: rig.session)
        model.draft = "Anyone?"
        #expect(model.state.nobodyElse)
        #expect(!model.canSend)
        #expect(
            model.state.messages.compactMap(\.notice) == [
                Copy.Groups.created(by: rig.session.directory.label(for: sam.nodeId).text),
                Copy.Groups.left(rig.session.directory.label(for: sam.nodeId).text),
            ])
    }

    @Test func aPendingGroupMessageWaitsForAMembersKey() async {
        let rig = AppRig()
        let group = await rig.group([sam], createdBy: sam)
        await rig.receive("Soon", from: rig.me, in: group, pendingKey: true)
        let status = ChatModel(conversationId: group.id, session: rig.session).state.messages.last?.status
        #expect(status == .waitingForMembersKeys)
        #expect(status?.label == Copy.Groups.waitingForKeys)
        #expect(ChatListModel(session: rig.session).state.rows.last?.lastStatus == .waitingForMembersKeys)
    }

    @Test func aThreadForAGroupWeLeftIsGone() async throws {
        let rig = AppRig()
        let group = try #require(await rig.session.createGroup(with: [sam.nodeId, priya.nodeId]))
        let model = ChatModel(conversationId: group.id, session: rig.session)
        #expect(model.state.exists)
        await rig.session.leaveGroup(group.id)
        #expect(!model.state.exists)
        #expect(ChatModel(conversationId: Conversations.nearby, session: rig.session).state.exists)
    }

    // MARK: Group info

    @Test func groupInfoListsUsFirstThenWhoIsLinkedThenByName() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam", verified: true)
        await rig.pin(priya, name: "Priya")
        await rig.pin(stranger, name: "Ana")
        let group = await rig.group([sam, priya, stranger], createdBy: sam)
        await rig.session.handle(.neighborsChanged([Neighbor(nodeId: priya.nodeId)]))
        let state = GroupInfoModel(groupId: group.id, session: rig.session).state
        #expect(state.members.map(\.label) == [Copy.Common.you, "Priya", "Ana", "Sam"])
        #expect(state.members.map(\.isLinked) == [false, true, false, false])
        #expect(state.members.first?.peer == nil && state.members.first?.isMe == true)
        #expect(state.members.last?.isVerified == true && state.members.last?.peer == sam.nodeId)
        #expect(state.memberCount == 4 && state.exists)
    }

    @Test func renamingStartsFromTheTitleAndTakesOnlyARealName() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        let group = await rig.group([sam], createdBy: sam)
        let model = GroupInfoModel(groupId: group.id, session: rig.session)
        model.beginRename()
        #expect(model.draftName == "Sam")
        model.draftName = String(repeating: "n", count: 40)
        #expect(model.draftName.utf16.count == TextLimits.groupName)
        model.draftName = " \t "
        #expect(!model.canRename)
        #expect(!(await model.rename()))
        model.draftName = "Hikers"
        #expect(model.canRename)
        #expect(await model.rename())
        #expect(model.state.title == "Hikers")
    }

    @Test func leavingGoesThroughTheSessionAndTheGroupIsGone() async {
        let rig = AppRig()
        let group = await rig.group([sam], createdBy: sam)
        let model = GroupInfoModel(groupId: group.id, session: rig.session)
        await model.leave()
        #expect(rig.mesh.calls.groups == ["leave \(group.id)"])
        #expect(!model.state.exists && model.state.members.isEmpty)
    }

    // MARK: The picker

    @Test func thePickerOffersThePeopleWeKnowAndNeverUs() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya", verified: true)
        rig.stores.conversations.accept(sam.nodeId.string)
        await rig.receive("Hey", from: sam.nodeId, to: rig.me)
        await rig.receive("Who's this?", from: stranger.nodeId, to: rig.me)
        let picker = NewGroupModel(session: rig.session)
        #expect(picker.candidates.map(\.id) == [priya.nodeId, sam.nodeId], "a stranger's request lends nobody")
        let theirs = await rig.group([stranger, sam], createdBy: sam)
        await rig.receive("Hi", from: sam.nodeId, in: theirs)
        rig.stores.conversations.accept(theirs.id)
        await rig.session.handle(.groupChanged(theirs.id))
        #expect(picker.candidates.map(\.id).contains(stranger.nodeId), "an accepted group's members join in")
        #expect(!picker.candidates.map(\.id).contains(rig.me))
    }

    @Test func thePickerTakesTwoToSevenAndSaysWhenItIsFull() async throws {
        let rig = AppRig()
        let people = (10..<18).map { Person(seed: $0) }
        let picker = NewGroupModel(session: rig.session)
        #expect(await picker.create() == nil)
        picker.toggle(people[0].nodeId)
        #expect(!picker.canCreate, "one other is a DM")
        for person in people.dropFirst() {
            picker.toggle(person.nodeId)
        }
        #expect(picker.picked.count == NewGroupModel.maxOthers && picker.isFull)
        #expect(!picker.isPicked(people[7].nodeId))
        picker.toggle(people[0].nodeId)
        #expect(!picker.isFull && !picker.isPicked(people[0].nodeId))
        let id = try #require(await picker.create())
        #expect(rig.stores.groups.group(id)?.members.first == people[1].nodeId.string, "the roster keeps the pick order")
    }

    // MARK: Notifications

    @Test func aGroupMessageNotifiesUnderTheGroupWithItsSpeaker() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam", verified: true)
        let group = await rig.group([sam, priya], name: "Hikers", createdBy: sam)
        await rig.receive("Trail's open", from: sam.nodeId, in: group)
        let posted = rig.notifier.posted.last
        #expect(posted?.title == "Hikers" && posted?.threadId == group.id && posted?.conversationId == group.id)
        #expect(posted?.body == Copy.Notifications.roomBody(sender: "Sam", body: "Trail's open"))
    }
}
