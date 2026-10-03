import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// The chat list: the room pinned first, accepted DMs by their newest message, requests counted apart, and the
/// status line over it all (`ChatListAssembler` in knit-next).
@MainActor
@Suite struct ChatListTests {
    @Test func aFreshInstallShowsTheEmptyRoomAndTheFirstRunCard() {
        let rig = AppRig()
        let state = ChatListModel(session: rig.session).state
        #expect(state.rows.map(\.id) == [Conversations.nearby])
        #expect(state.rows.first?.title == Copy.ChatList.nearby)
        #expect(state.rows.first?.preview == nil)
        #expect(state.rows.first?.isRoom == true)
        #expect(state.showsGettingStarted)
        #expect(state.requestCount == 0)
    }

    @Test func theRoomStaysFirstAndDMsFollowNewestFirst() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        await rig.pin(AppRig.priya, name: "Priya")
        rig.stores.conversations.accept(AppRig.sam.nodeId.string)
        rig.stores.conversations.accept(AppRig.priya.nodeId.string)
        await rig.receive("Room, newest of all", from: AppRig.sam.nodeId, sentAt: 900)
        await rig.receive("Old", from: AppRig.sam.nodeId, to: rig.me, sentAt: 100)
        await rig.receive("Newer", from: AppRig.priya.nodeId, to: rig.me, sentAt: 500)
        let state = ChatListModel(session: rig.session).state
        #expect(state.rows.map(\.title) == [Copy.ChatList.nearby, "Priya", "Sam"])
        #expect(!state.showsGettingStarted)
    }

    @Test func aPreviewNamesItsSpeakerUnlessTheTitleAlreadyDoes() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        rig.stores.conversations.accept(AppRig.sam.nodeId.string)
        await rig.receive("Line one\nline two", from: AppRig.sam.nodeId, sentAt: 1)
        await rig.receive("Just the words", from: AppRig.sam.nodeId, to: rig.me, sentAt: 2)
        let rows = ChatListModel(session: rig.session).state.rows
        #expect(rows[0].preview == "Sam: Line one line two", "on one line")
        #expect(rows[1].preview == "Just the words")
        await rig.session.send("Mine", in: AppRig.sam.nodeId.string)
        #expect(ChatListModel(session: rig.session).state.rows[1].preview == "You: Mine")
    }

    @Test func onlyOurOwnNewestMessageCarriesATick() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        rig.stores.conversations.accept(AppRig.sam.nodeId.string)
        await rig.receive("Theirs", from: AppRig.sam.nodeId, to: rig.me, sentAt: 1)
        let model = ChatListModel(session: rig.session)
        #expect(model.state.rows[1].lastStatus == nil)
        let sent = await rig.session.send("Mine", in: AppRig.sam.nodeId.string)
        #expect(model.state.rows[1].lastStatus == .sent)
        rig.stores.messages.markDelivered(sent?.id ?? "")
        await rig.session.handle(.delivered(messageId: sent?.id ?? ""))
        #expect(model.state.rows[1].lastStatus == .delivered)
    }

    @Test func aStrangersDMIsCountedAsARequestNotListed() async {
        let rig = AppRig()
        await rig.receive("Hi, who's this?", from: AppRig.stranger.nodeId, to: rig.me)
        let state = ChatListModel(session: rig.session).state
        #expect(state.rows.map(\.id) == [Conversations.nearby])
        #expect(state.requestCount == 1)
        #expect(!state.showsGettingStarted, "a request is something to do")
    }

    @Test func aDMWeWroteInOrAPeerWeVerifiedIsNoRequest() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam", verified: true)
        await rig.receive("Verified", from: AppRig.sam.nodeId, to: rig.me)
        await rig.receive("Hello?", from: AppRig.priya.nodeId, to: rig.me)
        await rig.session.send("Yes, hello", in: AppRig.priya.nodeId.string)
        let state = ChatListModel(session: rig.session).state
        #expect(state.requestCount == 0)
        #expect(state.rows.count == 3)
        #expect(state.rows.first { $0.id == AppRig.sam.nodeId.string }?.isVerified == true)
    }

    @Test func aThreadNamedForNoNodeIdIsLeftOut() async {
        let rig = AppRig()
        let group = MessageRecord(
            id: "g", senderId: AppRig.sam.nodeId, recipientId: nil, conversationId: "group-1", body: "Group", sentAt: 5)
        rig.stores.messages.save(group)
        await rig.session.handle(.received(group, isRequest: false))
        let state = ChatListModel(session: rig.session).state
        #expect(state.rows.map(\.id) == [Conversations.nearby])
        #expect(state.requestCount == 0)
    }

    @Test func aLinkedPeersRowSaysSoWithoutAStoreRead() async {
        let rig = AppRig()
        rig.stores.conversations.accept(AppRig.sam.nodeId.string)
        await rig.receive("Hi", from: AppRig.sam.nodeId, to: rig.me)
        let model = ChatListModel(session: rig.session)
        #expect(model.state.rows[1].isLinked == false)
        await rig.session.handle(.neighborsChanged([Neighbor(nodeId: AppRig.sam.nodeId)]))
        #expect(model.state.rows[1].isLinked)
    }

    @Test func theStateIsRebuiltOnlyWhenSomethingChanged() async {
        let rig = AppRig()
        let model = ChatListModel(session: rig.session)
        let first = model.state
        rig.stores.messages.save(
            MessageRecord(
                id: "quiet", senderId: AppRig.sam.nodeId, recipientId: nil, conversationId: Conversations.nearby, body: "x", sentAt: 1)
        )
        #expect(model.state == first, "a write the session never heard of waits for the next revision")
        await rig.session.handle(.peerUpdated(AppRig.sam.nodeId))
        #expect(model.state.rows[0].preview != nil)
    }

    @Test func theStatusLineFollowsTheRadioAndTheMesh() async {
        let rig = AppRig()
        let model = ChatListModel(session: rig.session)
        #expect(model.status == .stopped)
        await model.start()
        #expect(model.status == .starting)
        await rig.session.handle(.radioChanged(.on))
        #expect(model.status == .linked(0))
        #expect(model.status.line == Copy.Status.looking)
        await rig.session.handle(.neighborsChanged([Neighbor(nodeId: AppRig.sam.nodeId), Neighbor(nodeId: AppRig.priya.nodeId)]))
        #expect(model.status.line == Copy.Status.linked(2))
    }

    @Test(arguments: [
        (RadioState?.none, true, 0, ConnectionStatus.starting),
        (.none, false, 0, .stopped),
        (.on, true, 3, .linked(3)),
        (.on, false, 0, .stopped),
        (.off, true, 0, .bluetoothOff),
        (.off, false, 0, .stopped),
        (.unauthorized, false, 0, .notAllowed),
        (.unauthorized, true, 0, .notAllowed),
        (.unsupported, true, 0, .unsupported),
        (.unsupported, false, 0, .unsupported),
    ])
    func eachReasonTheRadioCannotRunHasItsOwnLine(radio: RadioState?, running: Bool, linked: Int, expected: ConnectionStatus) {
        #expect(ConnectionStatus(radio: radio, isRunning: running, linked: linked) == expected)
    }

    @Test func onlyAStoppedMeshOffersStartOnlyARefusalOffersSettingsAndOnlyARunningOneExplains() {
        let all: [ConnectionStatus] = [.linked(1), .starting, .stopped, .bluetoothOff, .notAllowed, .unsupported]
        #expect(all.filter(\.offersStart) == [.stopped])
        #expect(all.filter(\.offersSettings) == [.notAllowed])
        #expect(all.filter(\.offersBoundary) == [.linked(1)])
        #expect(all.filter(\.isWarning) == [.stopped, .bluetoothOff, .notAllowed, .unsupported])
        #expect(Set(all.map(\.line)).count == all.count)
    }

    /// The device tests wait on the state the line's identifier names, so every state has its own, and a mesh with no
    /// peer yet is still looking.
    @Test func eachLineNamesItsOwnStateForTheDeviceTests() {
        let all: [ConnectionStatus] = [.linked(2), .linked(0), .starting, .stopped, .bluetoothOff, .notAllowed, .unsupported]
        #expect(all.map(\.accessibilityState) == AccessibilityID.StatusState.allCases)
    }
}
