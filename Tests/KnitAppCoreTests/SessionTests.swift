import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// The session: what the mesh reports, the actions the screens take, and what reaches a notification.
@MainActor
@Suite struct SessionTests {
    @Test func whatTheMeshReportsIsKeptAndEachMessageMovesTheRevision() async {
        let rig = AppRig()
        await rig.session.handle(.radioChanged(.on))
        #expect(rig.session.radioState == .on)
        await rig.session.handle(.neighborsChanged([Neighbor(nodeId: AppRig.sam.nodeId)]))
        #expect(rig.session.neighbors.map(\.nodeId) == [AppRig.sam.nodeId])
        let before = rig.session.revision
        await rig.session.handle(.delivered(messageId: "x"))
        await rig.session.handle(.sent(messageId: "x"))
        await rig.session.handle(.peerUpdated(AppRig.sam.nodeId))
        #expect(rig.session.revision == before + 3)
        await rig.session.handle(.neighborsChanged([]))
        #expect(rig.session.revision == before + 3, "a link changes no stored thread")
    }

    @Test func listeningHandsOnEveryEventUntilTheStreamEnds() async {
        let rig = AppRig(radio: .off)
        rig.mesh.emit(.radioChanged(.on))
        rig.mesh.emit(.neighborsChanged([Neighbor(nodeId: AppRig.sam.nodeId)]))
        rig.mesh.finish()
        await rig.session.listen()
        #expect(rig.session.radioState == .on)
        #expect(rig.session.neighbors.count == 1)
        await rig.session.listen()
        #expect(rig.session.radioState == .on, "a second listen returns at once")
    }

    @Test func startAndStopFollowTheMesh() async {
        let rig = AppRig()
        #expect(!rig.session.isRunning)
        await rig.session.start()
        #expect(rig.session.isRunning)
        await rig.session.stop()
        #expect(!rig.session.isRunning)
        #expect(rig.mesh.calls.starts == 1)
        #expect(rig.mesh.calls.stops == 1)
    }

    @Test func aSendGoesToTheRoomOrToTheThreadsPeer() async throws {
        let rig = AppRig()
        let post = try #require(await rig.session.send("  Hello room  ", in: Conversations.nearby))
        #expect(post.body == "Hello room", "trimmed at its ends")
        await rig.session.send("Hi Sam", in: AppRig.sam.nodeId.string)
        #expect(rig.mesh.calls.room == ["Hello room"])
        #expect(rig.mesh.calls.direct == ["\(AppRig.sam.nodeId): Hi Sam"])
    }

    @Test func nothingIsSentWhereThereIsNothingToSendOrNobodyToSendTo() async {
        let rig = AppRig()
        let revision = rig.session.revision
        #expect(await rig.session.send(" \n\t ", in: Conversations.nearby) == nil)
        #expect(await rig.session.send("Hi", in: "not a node id") == nil)
        #expect(await rig.session.send("Hi me", in: rig.me.string) == nil, "no thread with ourselves")
        #expect(rig.mesh.calls.room.isEmpty && rig.mesh.calls.direct.isEmpty)
        #expect(rig.session.revision == revision)
    }

    @Test func theDirectoryLabelsEveryoneAndFollowsTheRevision() async {
        let rig = AppRig()
        #expect(rig.session.directory.label(for: AppRig.sam.nodeId).text == Alias.alias(for: AppRig.sam.nodeId.string))
        await rig.pin(AppRig.sam, name: "Sam")
        #expect(rig.session.directory.label(for: AppRig.sam.nodeId).text == "Sam")
        await rig.session.updateProfile(name: "Sam", status: "", openToChat: false)
        let sam = rig.session.directory.label(for: AppRig.sam.nodeId)
        #expect(sam.discriminator != nil, "our own name joins the universe")
    }

    @Test func verifyingAndAcceptingGoThroughTheMesh() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        await rig.session.setVerified(AppRig.sam.nodeId, true)
        #expect(rig.session.directory.verified == [AppRig.sam.nodeId])
        await rig.session.accept(AppRig.priya.nodeId.string)
        #expect(rig.mesh.calls.accepted == [AppRig.priya.nodeId.string])
        #expect(rig.stores.conversations.acceptedConversations() == [AppRig.priya.nodeId.string])
    }

    @Test func theMeshsCountersAreReadThroughTheSession() async {
        let rig = AppRig()
        #expect(await rig.session.diagnostics() == MeshDiagnostics())
    }

    // MARK: Notifications

    @Test func anAcceptedDMNotifiesUnderItsSendersName() async throws {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        rig.stores.conversations.accept(AppRig.sam.nodeId.string)
        let message = await rig.receive("See you at 6", from: AppRig.sam.nodeId, to: rig.me)
        let posted = try #require(rig.notifier.posted.first)
        let expected = LocalNotification(
            id: message.id,
            threadId: message.conversationId,
            conversationId: message.conversationId,
            title: "Sam",
            body: "See you at 6"
        )
        #expect(posted == expected)
    }

    @Test func aRoomPostNotifiesUnderTheRoomWithItsSpeaker() async throws {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        await rig.receive("Anyone here?", from: AppRig.sam.nodeId)
        let posted = try #require(rig.notifier.posted.first)
        #expect(posted.title == Copy.Notifications.nearbyTitle)
        #expect(posted.body == "Sam: Anyone here?")
        #expect(posted.threadId == Conversations.nearby)
    }

    @Test func requestsShareOneNotificationThatCountsThemAndShowsNoWords() async {
        let rig = AppRig()
        await rig.receive("Secret words", from: AppRig.stranger.nodeId, to: rig.me)
        await rig.receive("More words", from: AppRig.priya.nodeId, to: rig.me)
        let posted = rig.notifier.posted
        #expect(posted.map(\.id) == [NotificationPolicy.requestsThread, NotificationPolicy.requestsThread])
        #expect(posted.last?.body == Copy.Notifications.requestBody(2))
        #expect(posted.allSatisfy { !$0.body.contains("words") && $0.conversationId == nil })
    }

    @Test func theThreadOnScreenStaysQuietOnlyWhileTheAppIsInFront() async {
        let rig = AppRig()
        rig.stores.conversations.accept(AppRig.sam.nodeId.string)
        await rig.session.show(AppRig.sam.nodeId.string)
        #expect(rig.notifier.withdrawn == [AppRig.sam.nodeId.string], "what it posted before goes")
        await rig.receive("On screen", from: AppRig.sam.nodeId, to: rig.me)
        #expect(rig.notifier.posted.isEmpty)
        rig.session.isActive = false
        await rig.receive("Screen locked", from: AppRig.sam.nodeId, to: rig.me)
        #expect(rig.notifier.posted.map(\.body) == ["Screen locked"])
        rig.session.isActive = true
        rig.session.hide(AppRig.priya.nodeId.string)
        await rig.receive("Still on screen", from: AppRig.sam.nodeId, to: rig.me)
        #expect(rig.notifier.posted.count == 1, "hiding another thread leaves this one on screen")
        rig.session.hide(AppRig.sam.nodeId.string)
        await rig.receive("Gone", from: AppRig.sam.nodeId, to: rig.me)
        #expect(rig.notifier.posted.map(\.body) == ["Screen locked", "Gone"])
    }

    @Test func ourOwnMessagesNeverNotify() async {
        let rig = AppRig()
        await rig.receive("Mine", from: rig.me)
        #expect(rig.notifier.posted.isEmpty)
    }

    @Test func acceptingTheLastRequestTakesItsNotificationBack() async {
        let rig = AppRig()
        await rig.receive("Hi", from: AppRig.stranger.nodeId, to: rig.me)
        await rig.receive("Hi", from: AppRig.priya.nodeId, to: rig.me)
        await rig.session.accept(AppRig.stranger.nodeId.string)
        #expect(rig.notifier.withdrawn.isEmpty, "one request still waits")
        await rig.session.accept(AppRig.priya.nodeId.string)
        #expect(rig.notifier.withdrawn == [NotificationPolicy.requestsThread])
    }

    @Test func aSessionWithoutANotifierStaysQuiet() async {
        let stores = MeshStores.inMemory()
        let session = AppSession(
            identity: OwnIdentity(bundle: AppRig.me.bundle),
            stores: stores,
            mesh: FakeMesh(nodeId: AppRig.me.nodeId, stores: stores)
        )
        let message = MessageRecord(
            id: "m", senderId: AppRig.sam.nodeId, recipientId: nil, conversationId: Conversations.nearby, body: "hi", sentAt: 1)
        await session.handle(.received(message, isRequest: false))
        await session.show(Conversations.nearby)
        await session.accept(AppRig.sam.nodeId.string)
        #expect(session.revision == 2)
    }
}
