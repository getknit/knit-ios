import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// `-seedDemo`: its launch options, its radio, its scenes, and what they seed, driven through a real mesh.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct DemoTests {
    @Test func theLaunchOptionsReadTheDemoAndItsRadio() {
        #expect(!LaunchOptions(arguments: ["Knit"]).seedDemo)
        let demo = LaunchOptions(arguments: ["Knit", "-seedDemo", "-demoRadio", "unsupported"])
        #expect(demo.seedDemo)
        #expect(demo.demoRadio == .unsupported)
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoRadio", "sideways"]).demoRadio == .on)
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoRadio"]).demoRadio == .on, "a flag with no value")
        #expect(LaunchOptions(arguments: ["-demoRadio", "off"]).demoRadio == .off)
        #expect(demo.demoScene == .edgeCases, "the default scene")
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoScene", "marketing"]).demoScene == .marketing)
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoScene", "edge-cases"]).demoScene == .edgeCases)
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoScene", "sideways"]).demoScene == .edgeCases)
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoScene"]).demoScene == .edgeCases, "a flag with no value")
        #expect(!demo.demoOnboarding, "the demo starts at the chat list")
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoOnboarding"]).demoOnboarding)
    }

    @Test func theLaunchOptionsReadTheDemosCamera() {
        #expect(LaunchOptions(arguments: ["-seedDemo"]).demoCamera == nil, "the device's own camera")
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoCamera", "denied"]).demoCamera == .denied)
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoCamera", "allowed"]).demoCamera == .allowed)
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoCamera", "sideways"]).demoCamera == nil)
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoCamera"]).demoCamera == nil, "a flag with no value")
    }

    @Test func theLaunchOptionsReadTheDemosNotification() {
        #expect(!LaunchOptions(arguments: ["-seedDemo"]).demoNotification)
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoNotification"]).demoNotification)
    }

    /// What `-demoNotification` posts, and the UI test taps to open the room: what the room's newest post by someone else
    /// makes.
    @Test func theDemosNotificationIsTheRoomsNewestPostBySomeoneElse() throws {
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        #expect(DemoSeed.notification(in: stores, me: identity.nodeId) == nil, "an empty room")
        DemoSeed.populate(stores, me: identity.nodeId, now: 1_000_000, scene: .edgeCases)
        let notification = try #require(DemoSeed.notification(in: stores, me: identity.nodeId))
        #expect(notification.conversationId == Conversations.nearby)
        #expect(notification.title == Copy.Notifications.nearbyTitle)
        #expect(notification.body == Copy.Notifications.roomBody(sender: "Priya", body: "On my way."))
    }

    @Test(arguments: DemoCamera.Answer.allCases)
    func theDemosCameraScansAndAnswersWhatItWasTold(answer: DemoCamera.Answer) async {
        let model = CodeScannerModel(camera: DemoCamera(answer))
        await model.prepare()
        #expect(model.phase == (answer == .allowed ? .scanning : .denied))
    }

    @Test(arguments: DemoScene.allCases)
    func theSeedIsTheSameEveryLaunch(scene: DemoScene) throws {
        let first = try #require(DemoSeed.identity)
        let second = try #require(DemoSeed.identity)
        #expect(first.nodeId == second.nodeId)
        let once = MeshStores.inMemory()
        let again = MeshStores.inMemory()
        DemoSeed.populate(once, me: first.nodeId, now: 1_000_000, scene: scene)
        DemoSeed.populate(again, me: first.nodeId, now: 1_000_000, scene: scene)
        #expect(once.peers.allPeers() == again.peers.allPeers())
        #expect(once.messages.threadHeads() == again.messages.threadHeads())
        #expect(once.ownProfile.load() == again.ownProfile.load())
        #expect(once.blocks.blockedNodeIds() == again.blocks.blockedNodeIds())
    }

    @Test func theDemoShowsARoomADMARequestAndTwoSams() async throws {
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 10_000_000, scene: .edgeCases)
        #expect(DemoSeed.linked(in: .edgeCases).isEmpty)
        let radio = DemoRadio(state: .unsupported)
        let mesh = Mesh(
            identity: identity,
            deviceTag: nil,
            stores: stores,
            radio: radio,
            clock: DemoClock(),
            random: SystemRandomNumberGenerator()
        )
        let session = AppSession(identity: OwnIdentity(bundle: identity.bundle), stores: stores, mesh: mesh)
        let list = ChatListModel(session: session).state
        #expect(list.rows.count == 3)
        #expect(list.requestCount == 1)
        #expect(BlockedModel(session: session).rows.map(\.title) == ["Jonas"], "someone blocked, for Settings to list")
        #expect(list.rows[0].preview?.hasPrefix("Priya: ") == true)
        #expect(list.rows[1].title.hasPrefix("Sam ("), "two Sams, told apart")
        #expect(list.rows[1].isVerified)
        #expect(
            list.rows[2].isGroup && list.rows[2].preview?.hasPrefix(Copy.Common.you) == true, "an unnamed group, titled for its members")
        let group = try #require(stores.groups.groups().first)
        #expect(group.departed.count == 1, "one Sam left")
        #expect(stores.messages.messages(in: group.id).map(\.kind) == [.groupCreated, .memberLeft, .message, .message])
        let listening = Task { await session.listen() }
        await session.start()
        while session.radioState == nil {
            await Task.yield()
        }
        #expect(session.radioState == .unsupported)
        #expect(ChatListModel(session: session).status == .unsupported)
        await session.send("Nobody hears this", in: Conversations.nearby)
        #expect(await session.diagnostics().neighbors.isEmpty)
        #expect(stores.messages.messages(in: Conversations.nearby).last?.body == "Nobody hears this")
        listening.cancel()
    }

    @Test func theMarketingSceneNamesEveryoneAndLinksThree() async throws {
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 100_000_000, scene: .marketing)
        #expect(stores.ownProfile.load().name == "Maya Okonkwo")
        let names = stores.peers.allPeers().map(\.name)
        #expect(!names.contains(""), "nobody shown by alias")
        #expect(Set(names).count == names.count, "nobody told apart by alias")
        let linked = DemoSeed.linked(in: .marketing)
        #expect(linked.count == 3)
        let (session, mesh) = Self.session(stores, identity: identity, radio: .on, linked: linked)
        let list = ChatListModel(session: session)
        #expect(list.state.rows.map(\.title) == ["Nearby", "Sam Rivera", "Summit crew", "Dani Cho"])
        #expect(list.state.requestCount == 1)
        #expect(list.state.rows[3].isVerified)
        #expect(list.state.rows.dropFirst().allSatisfy { $0.lastStatus == .delivered || $0.lastStatus == nil })
        let listening = Task { await session.listen() }
        await session.start()
        while session.neighbors.count < 3 {
            await Task.yield()
        }
        #expect(list.status == .linked(3))
        let everyDMLinked = list.state.rows.dropFirst().filter { !$0.isGroup }.allSatisfy(\.isLinked)
        #expect(everyDMLinked)
        #expect(await session.diagnostics().neighbors.map(\.nodeId) == linked)
        await session.stop()
        while !session.neighbors.isEmpty {
            await Task.yield()
        }
        #expect(list.status == .stopped)
        #expect(await mesh.neighbors.isEmpty)
        listening.cancel()
    }

    /// The demo's words wait for the content filter as the engine's do, and the session screens them as it starts
    /// listening: under `-demoSensitive` every one from someone else hides, and otherwise none does (ADR 2026-10.e4kz).
    @Test(arguments: [true, false])
    func theDemoScreensItsWordsAsItStartsListening(sensitive: Bool) async throws {
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 100_000_000, scene: .marketing)
        let room = stores.messages.messages(in: Conversations.nearby)
        #expect(room.allSatisfy { $0.moderation == ($0.senderId == identity.nodeId ? .clear : .waiting) })
        let node = Mesh(
            identity: identity,
            deviceTag: nil,
            stores: stores,
            radio: DemoRadio(state: .on),
            clock: DemoClock(),
            random: SystemRandomNumberGenerator()
        )
        let screening = TextScreening(
            classifier: DemoTextClassifier(flagsEverything: sensitive), words: WordFilter(words: []), slurs: WordFilter(words: [])
        )
        let session = AppSession(
            identity: OwnIdentity(bundle: identity.bundle),
            stores: stores,
            mesh: DemoMesh(node, linked: []),
            textScreening: screening
        )
        let listening = Task { await session.listen() }
        while !stores.messages.waitingForModeration().isEmpty {
            await Task.yield()
        }
        let theirs = stores.messages.messages(in: Conversations.nearby).filter { $0.senderId != identity.nodeId }
        #expect(!theirs.isEmpty && theirs.allSatisfy { $0.moderation == (sensitive ? .flagged : .clear) })
        listening.cancel()
    }

    @Test func aRadioThatCannotRunShowsNobodyLinked() async throws {
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 100_000_000, scene: .marketing)
        let (session, mesh) = Self.session(stores, identity: identity, radio: .off, linked: DemoSeed.linked(in: .marketing))
        let listening = Task { await session.listen() }
        await session.start()
        while session.radioState == nil {
            await Task.yield()
        }
        #expect(session.radioState == .off)
        #expect(session.neighbors.isEmpty)
        #expect(await mesh.neighbors.isEmpty)
        #expect(ChatListModel(session: session).status == .bluetoothOff)
        listening.cancel()
    }

    /// A session over a real mesh on the demo's radio, in `radio`'s state, showing `linked` as linked.
    private static func session(
        _ stores: MeshStores,
        identity: IdentityKeys,
        radio: RadioState,
        linked: [NodeId]
    ) -> (AppSession, DemoMesh) {
        let node = Mesh(
            identity: identity,
            deviceTag: nil,
            stores: stores,
            radio: DemoRadio(state: radio),
            clock: DemoClock(),
            random: SystemRandomNumberGenerator()
        )
        let mesh = DemoMesh(node, linked: linked)
        return (AppSession(identity: OwnIdentity(bundle: identity.bundle), stores: stores, mesh: mesh), mesh)
    }

    @Test func theDemoRadioGoesNowhere() async {
        let radio = DemoRadio(state: .on)
        #expect(!radio.advertisesServiceData && !radio.dialsGattPeers && !radio.servesDoorbell)
        radio.start()
        radio.advertise(AdvertPayload(capabilities: 0, nodeId: AppRig.me.nodeId, digestCue: 0, psm: 0))
        radio.write([1], to: ChannelID(1))
        radio.close(ChannelID(1))
        let channel = radio.dial(RadioAddress("x"), psm: 0x81)
        radio.stop()
        var events = radio.events.makeAsyncIterator()
        #expect(await events.next() == .state(.on))
        #expect(await events.next() == .dialFailed(channel))
    }

    @Test func theDemoMeshPassesEverythingButTheLinksThrough() async {
        let sam = Person(seed: 7)
        let fake = FakeMesh(nodeId: AppRig.me.nodeId, stores: MeshStores.inMemory(), radio: .on)
        let mesh = DemoMesh(fake, linked: [sam.nodeId])
        let shown = [Neighbor(nodeId: sam.nodeId)]
        #expect(mesh.nodeId == fake.nodeId)
        await mesh.start()
        let posted = await mesh.postToRoom("hi", photo: nil)
        #expect(posted != nil)
        #expect(await mesh.sendDirectMessage("hey", to: sam.nodeId, photo: nil) != nil)
        #expect(await mesh.deleteMessage(posted?.id ?? ""))
        #expect(await mesh.deleteChat(sam.nodeId.string))
        await mesh.accept("c1")
        await mesh.updateProfile(name: "Maya", status: "", openToChat: true)
        await mesh.setVerified(sam.nodeId, true)
        await mesh.block(sam.nodeId)
        await mesh.unblock(sam.nodeId)
        let group = await mesh.createGroup(with: [sam.nodeId])
        let id = group?.id ?? ""
        #expect(await mesh.sendGroupMessage("all", to: id, photo: nil) != nil)
        #expect(await mesh.renameGroup(id, to: "Pair")?.name == "Pair")
        #expect(await mesh.leaveGroup(id))
        let expected = FakeMesh.Calls(
            starts: 1,
            room: ["hi"],
            direct: ["\(sam.nodeId): hey"],
            accepted: ["c1"],
            verified: ["\(sam.nodeId): true"],
            blocked: ["block \(sam.nodeId)", "unblock \(sam.nodeId)"],
            profiles: ["Maya||true"],
            groups: ["create \(sam.nodeId)", "send \(id): all", "rename \(id): Pair", "leave \(id)"],
            deleted: ["message \(posted?.id ?? "")", "chat \(sam.nodeId)"]
        )
        #expect(fake.calls == expected)
        var events = mesh.events.makeAsyncIterator()
        #expect(await events.next() == .neighborsChanged(shown), "start shows the links")
        fake.emit(.delivered(messageId: "m1"))
        #expect(await events.next() == .delivered(messageId: "m1"))
        fake.emit(.neighborsChanged([]))
        #expect(await events.next() == .neighborsChanged(shown), "the links shown, whatever the mesh linked")
        fake.finish()
        #expect(await events.next() == nil)
    }
}

/// The wall and monotonic clocks, for a mesh whose timers never need to fire in a test.
private struct DemoClock: MeshClock {
    func wallMilliseconds() -> Int64 {
        10_000_000
    }

    func monotonicMilliseconds() -> Int64 {
        1000
    }

    func sleep(untilMonotonic _: Int64) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

// Reactions (ADR 2026-10.ehe6), apart from the suite's body only to keep it inside the lint's length.
extension DemoTests {
    @Test func theDemosReactionsShowAsEachThreadShowsThemAndATapReachesTheMesh() async throws {
        // ADR 2026-10.ehe6: our room post has a count above one and an emoji outside the six, and Jonas's heart stays
        // hidden behind his block; Sam's DM shows ours, and not the stranger's.
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 10_000_000, scene: .edgeCases)
        let (session, _) = Self.session(stores, identity: identity, radio: .on, linked: [])
        let room = ChatModel(conversationId: Conversations.nearby, session: session)
        let post = try #require(room.state.messages.first { $0.id == "room-3" })
        #expect(
            post.reactions == [
                ReactionChip(emoji: "\u{1F44D}", count: 2, mine: false), ReactionChip(emoji: "\u{1F525}", count: 1, mine: false),
            ])
        let sam = try #require(stores.peers.allPeers().first { $0.name == "Sam" && $0.verified })
        let direct = ChatModel(conversationId: sam.nodeId.string, session: session)
        #expect(direct.state.messages.first { $0.id == "dm-2" }?.reactions == [ReactionChip(emoji: "\u{1F44D}", count: 1, mine: true)])
        let first = try #require(room.state.messages.first { $0.id == "room-1" })
        await room.react(to: first, with: ReactionChoices.six[1])
        #expect(
            room.state.messages.first { $0.id == "room-1" }?.reactions == [
                ReactionChip(emoji: ReactionChoices.six[1], count: 1, mine: true)
            ])
    }
}
