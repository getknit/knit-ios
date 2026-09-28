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
        #expect(list.rows.count == 2)
        #expect(list.requestCount == 1)
        #expect(list.rows[0].preview?.hasPrefix("Priya: ") == true)
        #expect(list.rows[1].title.hasPrefix("Sam ("), "two Sams, told apart")
        #expect(list.rows[1].isVerified)
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
        #expect(list.state.rows.map(\.title) == ["Nearby", "Sam Rivera", "Dani Cho"])
        #expect(list.state.requestCount == 1)
        #expect(list.state.rows[2].isVerified)
        #expect(list.state.rows.dropFirst().allSatisfy { $0.lastStatus == .delivered || $0.lastStatus == nil })
        let listening = Task { await session.listen() }
        await session.start()
        while session.neighbors.count < 3 {
            await Task.yield()
        }
        #expect(list.status == .linked(3))
        let everyDMLinked = list.state.rows.dropFirst().allSatisfy(\.isLinked)
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
        #expect(await mesh.postToRoom("hi") != nil)
        #expect(await mesh.sendDirectMessage("hey", to: sam.nodeId) != nil)
        await mesh.accept("c1")
        await mesh.updateProfile(name: "Maya", status: "", openToChat: true)
        await mesh.setVerified(sam.nodeId, true)
        let expected = FakeMesh.Calls(
            starts: 1,
            room: ["hi"],
            direct: ["\(sam.nodeId): hey"],
            accepted: ["c1"],
            verified: ["\(sam.nodeId): true"],
            profiles: ["Maya||true"]
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
