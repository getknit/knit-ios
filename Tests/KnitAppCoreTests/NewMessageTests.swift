import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// New message's model (`ContactsViewModel` and `ContactsScreen` in knit-next): who can be picked, and what one pick
/// and several picks open.
@MainActor
@Suite struct NewMessageTests {
    private let sam = AppRig.sam
    private let priya = AppRig.priya
    private let stranger = AppRig.stranger

    @Test func thePickerOffersThePeopleWeKnowAndNeverUs() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.pin(priya, name: "Priya", verified: true)
        rig.stores.conversations.accept(sam.nodeId.string)
        await rig.receive("Hey", from: sam.nodeId, to: rig.me)
        await rig.receive("Who's this?", from: stranger.nodeId, to: rig.me)
        let picker = NewMessageModel(session: rig.session)
        #expect(picker.candidates.map(\.id) == [priya.nodeId, sam.nodeId], "a stranger's request lends nobody")
        let theirs = await rig.group([stranger, sam], createdBy: sam)
        await rig.receive("Hi", from: sam.nodeId, in: theirs)
        rig.stores.conversations.accept(theirs.id)
        await rig.session.handle(.groupChanged(theirs.id))
        #expect(picker.candidates.map(\.id).contains(stranger.nodeId), "an accepted group's members join in")
        #expect(!picker.candidates.map(\.id).contains(rig.me))
    }

    /// The order holds while the picker is open: someone coming into range keeps their row, and someone new joins the
    /// end. A picker opened afterwards sorts afresh.
    @Test func theOrderHoldsWhileThePickerIsOpen() async {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam", verified: true)
        await rig.pin(priya, name: "Priya", verified: true)
        let picker = NewMessageModel(session: rig.session)
        #expect(picker.candidates.map(\.id) == [priya.nodeId, sam.nodeId])
        await rig.session.handle(.neighborsChanged([Neighbor(nodeId: sam.nodeId)]))
        #expect(picker.candidates.map(\.id) == [priya.nodeId, sam.nodeId], "coming into range moves nobody")
        #expect(picker.candidates.last?.isLinked == true, "the in-range mark still changes")
        await rig.pin(stranger, name: "Ada", verified: true)
        #expect(picker.candidates.map(\.id) == [priya.nodeId, sam.nodeId, stranger.nodeId], "someone new joins the end")
        let reopened = NewMessageModel(session: rig.session)
        #expect(reopened.candidates.map(\.id) == [sam.nodeId, stranger.nodeId, priya.nodeId])
    }

    @Test func nothingPickedStartsNothing() async {
        let rig = AppRig()
        let picker = NewMessageModel(session: rig.session)
        #expect(!picker.canStart)
        #expect(await picker.start() == nil)
        #expect(rig.mesh.calls.groups.isEmpty)
    }

    /// One pick is a DM: the thread named for their node id, with no group made and nothing accepted, as Android's
    /// `onPickSingle` opens it.
    @Test func onePickOpensTheirDirectThread() async {
        let rig = AppRig()
        let picker = NewMessageModel(session: rig.session)
        picker.toggle(sam.nodeId)
        #expect(picker.canStart)
        #expect(await picker.start() == sam.nodeId.string)
        #expect(rig.mesh.calls.groups.isEmpty && rig.mesh.calls.accepted.isEmpty)
        #expect(rig.stores.groups.groups().isEmpty)
    }

    @Test func twoPicksStartAGroup() async throws {
        let rig = AppRig()
        let picker = NewMessageModel(session: rig.session)
        picker.toggle(sam.nodeId)
        picker.toggle(priya.nodeId)
        let id = try #require(await picker.start())
        #expect(rig.mesh.calls.groups == ["create \(sam.nodeId.string),\(priya.nodeId.string)"])
        #expect(Conversations.isGroup(id) && rig.stores.groups.group(id) != nil)
    }

    @Test func thePickerTakesUpToSevenAndSaysWhenItIsFull() async throws {
        let rig = AppRig()
        let people = (10..<18).map { Person(seed: $0) }
        let picker = NewMessageModel(session: rig.session)
        for person in people {
            picker.toggle(person.nodeId)
        }
        #expect(picker.picked.count == NewMessageModel.maxOthers && picker.isFull)
        #expect(!picker.isPicked(people[7].nodeId))
        picker.toggle(people[0].nodeId)
        #expect(!picker.isFull && !picker.isPicked(people[0].nodeId))
        let id = try #require(await picker.start())
        #expect(rig.stores.groups.group(id)?.members.first == people[1].nodeId.string, "the roster keeps the pick order")
    }
}
