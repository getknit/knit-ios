import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Unread counts and Knit's icon (ADR 2026-10.frmj): a count on each row of the chat list as Android draws it
/// (`ChatListViewModelTest`'s unread cases), read when the thread is on screen with Knit in front
/// (`ChatViewModelTest.theReadWatermarkFollowsTheThreadsNewestMessageNotTheWindowsPage`), and the DMs' and groups'
/// total on the icon, which Android does not have.
@MainActor
@Suite struct UnreadTests {
    private let sam = AppRig.sam
    private let priya = AppRig.priya
    private let stranger = AppRig.stranger

    /// The row of `conversationId` on the chat list, or `nil` when the list doesn't draw it.
    private func row(_ conversationId: String, in rig: AppRig) -> ChatRow? {
        ChatListModel(session: rig.session).state.rows.first { $0.id == conversationId }
    }

    /// A rig where Sam's DM is accepted. Pinning Sam already set the icon, at nothing.
    private func rigTalkingToSam() async -> AppRig {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        rig.stores.conversations.accept(sam.nodeId.string)
        return rig
    }

    @Test func anOffScreenArrivalCountsOnItsRow() async {
        let rig = await rigTalkingToSam()
        await rig.receive("One", from: sam.nodeId, to: rig.me, sentAt: 100)
        await rig.receive("Two", from: sam.nodeId, to: rig.me, sentAt: 200)
        await rig.session.send("Mine", in: sam.nodeId.string)
        #expect(row(sam.nodeId.string, in: rig)?.unreadCount == 2, "our own message never counts")
        #expect(row(Conversations.nearby, in: rig)?.unreadCount == 0)
        #expect(rig.notifier.badges == [0, 1, 2])
    }

    @Test func openingAThreadReadsItAndMovesTheRevisionOnce() async {
        let rig = await rigTalkingToSam()
        await rig.receive("One", from: sam.nodeId, to: rig.me, sentAt: 100)
        await rig.receive("Two", from: sam.nodeId, to: rig.me, sentAt: 200)
        let thread = ChatModel(conversationId: sam.nodeId.string, session: rig.session)
        let before = rig.session.revision
        await thread.appear()
        #expect(rig.session.revision == before + 1)
        #expect(row(sam.nodeId.string, in: rig)?.unreadCount == 0)
        #expect(rig.notifier.badges == [0, 1, 2, 0])
        thread.disappear()
        await thread.appear()
        #expect(rig.session.revision == before + 1, "a thread already read never redraws for it")
        #expect(rig.notifier.badges == [0, 1, 2, 0])
    }

    @Test func anArrivalInTheThreadOnScreenIsReadAtOnce() async {
        let rig = await rigTalkingToSam()
        await rig.session.show(sam.nodeId.string)
        await rig.receive("Hi", from: sam.nodeId, to: rig.me)
        #expect(row(sam.nodeId.string, in: rig)?.unreadCount == 0)
        await rig.receive("In the room", from: sam.nodeId)
        #expect(row(Conversations.nearby, in: rig)?.unreadCount == 1, "only the thread on screen is read")
        #expect(rig.notifier.badges == [0])
    }

    @Test func anArrivalInTheBackgroundWaitsForTheReturn() async {
        // Android stamps on `ON_RESUME`: the thread still on screen when Knit comes back is read then.
        let rig = await rigTalkingToSam()
        await rig.session.show(sam.nodeId.string)
        await rig.session.setActive(false)
        await rig.receive("While you were away", from: sam.nodeId, to: rig.me)
        #expect(row(sam.nodeId.string, in: rig)?.unreadCount == 1)
        #expect(rig.notifier.badges == [0, 1])
        await rig.session.setActive(true)
        #expect(row(sam.nodeId.string, in: rig)?.unreadCount == 0)
        #expect(rig.notifier.badges == [0, 1, 0])
    }

    @Test func aThreadThatLeftTheScreenCountsAgain() async {
        let rig = await rigTalkingToSam()
        let thread = ChatModel(conversationId: sam.nodeId.string, session: rig.session)
        await thread.appear()
        thread.disappear()
        await rig.receive("Back on the list", from: sam.nodeId, to: rig.me)
        #expect(row(sam.nodeId.string, in: rig)?.unreadCount == 1)
    }

    @Test func aRequestCountsOnlyOnceAcceptedOrVerified() async {
        // Android draws no row for a request, so nothing counts it (`ChatListViewModel.kt:328-345`). Accepting one
        // without opening it shows all it holds.
        let rig = AppRig()
        await rig.receive("Who's this?", from: stranger.nodeId, to: rig.me, sentAt: 100)
        await rig.receive("Hello?", from: stranger.nodeId, to: rig.me, sentAt: 200)
        #expect(row(stranger.nodeId.string, in: rig) == nil)
        #expect(ChatListModel(session: rig.session).state.requestCount == 1)
        #expect(rig.notifier.badges == [0])
        await rig.session.accept(stranger.nodeId.string)
        #expect(row(stranger.nodeId.string, in: rig)?.unreadCount == 2)
        #expect(rig.notifier.badges == [0, 2])

        await rig.pin(priya, name: "Priya")
        await rig.receive("It's Priya", from: priya.nodeId, to: rig.me)
        #expect(row(priya.nodeId.string, in: rig) == nil)
        await rig.session.setVerified(priya.nodeId, true)
        #expect(row(priya.nodeId.string, in: rig)?.unreadCount == 1)
        #expect(rig.notifier.badges == [0, 2, 3])
    }

    @Test func aBlockHidesTheCountAndUnblockRestoresIt() async {
        let rig = await rigTalkingToSam()
        await rig.receive("One", from: sam.nodeId, to: rig.me, sentAt: 100)
        await rig.receive("Two", from: sam.nodeId, to: rig.me, sentAt: 200)
        await rig.receive("In the room", from: sam.nodeId, sentAt: 300)
        await rig.receive("Me too", from: priya.nodeId, sentAt: 400)
        #expect(row(Conversations.nearby, in: rig)?.unreadCount == 2)
        await rig.session.block(sam.nodeId)
        #expect(row(sam.nodeId.string, in: rig) == nil)
        #expect(row(Conversations.nearby, in: rig)?.unreadCount == 1, "what they wrote in the room stops counting")
        #expect(rig.notifier.badges.last == 0)
        await rig.session.unblock(sam.nodeId)
        #expect(row(sam.nodeId.string, in: rig)?.unreadCount == 2, "unread as it was")
        #expect(row(Conversations.nearby, in: rig)?.unreadCount == 2)
        #expect(rig.notifier.badges.last == 2)
    }

    @Test func aDeviceTagBlockUpdatesTheBadge() async {
        // The engine blocks a re-keyed phone by its profile's device tag and reports only the peer
        // (`MeshEngine+Profiles.continueBlock`, ADR 2026-10.5wgg).
        let rig = await rigTalkingToSam()
        await rig.receive("Hi", from: sam.nodeId, to: rig.me)
        rig.stores.blocks.block(sam.nodeId, deviceTag: nil)
        await rig.session.handle(.peerUpdated(sam.nodeId))
        #expect(rig.notifier.badges == [0, 1, 0])
    }

    @Test func theRoomCountsOnItsRowButNotOnTheIcon() async {
        let rig = AppRig()
        await rig.receive("Anyone around?", from: sam.nodeId, sentAt: 100)
        await rig.receive("Here", from: priya.nodeId, sentAt: 200)
        #expect(row(Conversations.nearby, in: rig)?.unreadCount == 2)
        #expect(rig.notifier.badges == [0], "set once, at nothing, and never moved by the room")
    }

    @Test func aLeftOrDeletedThreadCountsNothing() async {
        let rig = await rigTalkingToSam()
        await rig.pin(priya, name: "Priya")
        let group = await rig.group([sam, priya], createdBy: sam)
        rig.stores.conversations.accept(group.id)
        await rig.receive("Plans?", from: priya.nodeId, in: group)
        await rig.receive("Hi", from: sam.nodeId, to: rig.me)
        #expect(row(group.id, in: rig)?.unreadCount == 1)
        #expect(rig.notifier.badges.last == 2)
        await rig.session.leaveGroup(group.id)
        #expect(rig.notifier.badges.last == 1)
        await rig.session.deleteChat(sam.nodeId.string)
        #expect(rig.notifier.badges.last == 0)
        #expect(ChatListModel(session: rig.session).state.rows.map(\.unreadCount) == [0])
    }

    @Test func deletingAnUnreadMessageTakesItOffTheCount() async {
        let rig = await rigTalkingToSam()
        let first = await rig.receive("One", from: sam.nodeId, to: rig.me, sentAt: 100)
        await rig.receive("Two", from: sam.nodeId, to: rig.me, sentAt: 200)
        await rig.session.deleteMessage(first.id)
        #expect(row(sam.nodeId.string, in: rig)?.unreadCount == 1)
        #expect(rig.notifier.badges == [0, 1, 2, 1])
    }

    @Test func theBadgeIsSetAtLaunchAndOnlyWhenItChanges() async {
        // A launch sets the icon even to what it already shows, so one an earlier run left stale is put right.
        let rig = AppRig()
        rig.stores.conversations.accept(sam.nodeId.string)
        let held = MessageRecord(
            id: "held",
            senderId: sam.nodeId,
            recipientId: rig.me,
            conversationId: sam.nodeId.string,
            body: "From before",
            sentAt: 50,
            arrivedAt: 50
        )
        rig.stores.messages.save(held)
        rig.mesh.finish()
        await rig.session.listen()
        #expect(rig.notifier.badges == [1])
        await rig.receive("In the room", from: priya.nodeId)
        await rig.session.handle(.groupChanged("g-none"))
        await rig.session.setVerified(priya.nodeId, false)
        #expect(rig.notifier.badges == [1], "nothing the icon counts moved")
    }

    // MARK: The demo

    /// Every scene leaves unread exactly the lines it marks, each someone else's, the same at every launch.
    @Test(arguments: DemoScene.allCases)
    func aDemoSceneLeavesUnreadOnlyTheLinesItMarks(scene: DemoScene) throws {
        let identity = try #require(DemoSeed.identity)
        let once = MeshStores.inMemory()
        let again = MeshStores.inMemory()
        DemoSeed.populate(once, me: identity.nodeId, now: 1_000_000, scene: scene)
        DemoSeed.populate(again, me: identity.nodeId, now: 1_000_000, scene: scene)
        let counts = once.messages.unreadCounts(excludingSenders: [])
        #expect(counts == again.messages.unreadCounts(excludingSenders: []))
        let marked = scene.cast.lines.filter(\.unread)
        #expect(marked.allSatisfy { $0.from != .me }, "our own lines are never unread")
        #expect(counts.values.reduce(0, +) == marked.count)
        for line in marked {
            let thread = try #require(once.messages.message(line.id)?.conversationId)
            #expect(counts[ExactKey(thread)] != nil, "\(line.id) counts in its thread")
        }
    }

    /// What the shots and the walks see on the chat list: the room's reply waiting in the edge cases; Sam's two lines and
    /// the newest room post in the marketing scene; hundreds in the long room.
    @Test func theScenesCountWhereTheScreensShowIt() throws {
        let identity = try #require(DemoSeed.identity)
        func counts(_ scene: DemoScene) -> (stores: MeshStores, counts: [ExactKey: Int]) {
            let stores = MeshStores.inMemory()
            DemoSeed.populate(stores, me: identity.nodeId, now: 1_000_000, scene: scene)
            return (stores, stores.messages.unreadCounts(excludingSenders: stores.blocks.blockedNodeIds()))
        }
        let room = ExactKey(Conversations.nearby)
        #expect(counts(.edgeCases).counts[room] == 1)
        let marketing = counts(.marketing)
        let samsThread = try #require(marketing.stores.messages.message("dm-sam-3")?.conversationId)
        #expect(marketing.counts[room] == 1)
        #expect(marketing.counts[ExactKey(samsThread)] == 2)
        #expect((counts(.longRoom).counts[room] ?? 0) > 100)
    }

    @Test func theIconIsWhatTheListsRowsAddUpTo() async {
        let rig = await rigTalkingToSam()
        await rig.pin(priya, name: "Priya")
        rig.stores.conversations.accept(priya.nodeId.string)
        await rig.receive("One", from: sam.nodeId, to: rig.me, sentAt: 100)
        await rig.receive("Two", from: priya.nodeId, to: rig.me, sentAt: 200)
        await rig.receive("Three", from: priya.nodeId, to: rig.me, sentAt: 300)
        await rig.receive("Room", from: priya.nodeId, sentAt: 400)
        let rows = ChatListModel(session: rig.session).state.rows
        let total = rows.filter { $0.id != Conversations.nearby }.map(\.unreadCount).reduce(0, +)
        #expect(total == 3)
        #expect(ChatListAssembler.badgeTotal(rig.session.threads()) == total)
        #expect(rig.notifier.badges.last == total)
    }
}
