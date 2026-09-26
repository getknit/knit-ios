import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// `-seedDemo`: its launch options, its radio, and what it seeds, driven through a real mesh.
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
    }

    @Test func theSeedIsTheSameEveryLaunch() throws {
        let first = try #require(DemoSeed.identity)
        let second = try #require(DemoSeed.identity)
        #expect(first.nodeId == second.nodeId)
        let once = MeshStores.inMemory()
        let again = MeshStores.inMemory()
        DemoSeed.populate(once, me: first.nodeId, now: 1_000_000)
        DemoSeed.populate(again, me: first.nodeId, now: 1_000_000)
        #expect(once.peers.allPeers() == again.peers.allPeers())
        #expect(once.messages.threadHeads() == again.messages.threadHeads())
    }

    @Test func theDemoShowsARoomADMARequestAndTwoSams() async throws {
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 10_000_000)
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

    @Test func theDemoRadioGoesNowhere() async {
        let radio = DemoRadio(state: .on)
        #expect(!radio.advertisesServiceData && !radio.dialsGattPeers)
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
