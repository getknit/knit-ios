import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// The scripted scenes' director (ADR 2026-10.g3k9, ADR 2026-10.yddp): only the trailer and App Review's clips have a
/// script, and each plays through a real mesh, session and room, the trailer typing the user's part into the composer
/// and the block clip waiting for the user's report.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct DemoDirectorTests {
    @Test func onlyAScriptedSceneHasADirector() throws {
        let identity = try #require(DemoSeed.identity)
        let scenes = DemoScene.allCases.filter { scene in
            Self.director(of: scene, over: MeshStores.inMemory(), me: identity.nodeId) != nil
        }
        #expect(scenes == [.trailer, .block])
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoScene", "trailer"]).demoScene == .trailer)
    }

    /// The trailer opens on Sam linked and the room at its opening, and plays nothing until the room is on screen. Then
    /// the director types the user's post into the room's composer, which sends it, and the room answers it only once
    /// it is sent.
    @Test func theTrailersDirectorPlaysItsScriptThroughTheRoom() async throws {
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 100_000_000, scene: .trailer)
        let room = { stores.messages.messages(in: Conversations.nearby) }
        #expect(room().map(\.id) == ["room-1", "room-2", "room-3"])
        let director = try #require(Self.director(of: .trailer, over: stores, me: identity.nodeId))
        let session = Self.session(stores, identity: identity, director: director)
        let listening = Task { await session.listen() }
        await session.start()
        while session.neighbors.isEmpty {
            await Task.yield()
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        #expect(session.neighbors.count == 1 && room().count == 3, "nothing plays before the room is on screen")

        let chat = ChatModel(conversationId: Conversations.nearby, session: session)
        let following = Task { await chat.appear() }
        let mine = { room().filter { $0.senderId == identity.nodeId && $0.id.hasPrefix("room-") == false } }
        while !room().contains(where: { $0.id == "trailer-3" }) || mine().first?.delivered != true {
            await Task.yield()
        }
        #expect(mine().map(\.body) == ["Anyone still up top?"], "typed and sent in the composer")
        #expect(chat.draft.isEmpty, "the composer emptied by the send")
        #expect(stores.messages.message("trailer-3")?.attachment != nil, "Dani's post carries the fire")

        while chat.state.messages.first(where: { $0.id == "trailer-4" })?.reactions.isEmpty != false {
            await Task.yield()
        }
        #expect(mine().map(\.body) == ["Anyone still up top?"])
        #expect(session.neighbors.count == 3)
        #expect(chat.state.messages.first { $0.id == "trailer-2" }?.reactions == [ReactionChip(emoji: "\u{1F64F}", count: 2, mine: false)])
        following.cancel()
        listening.cancel()
    }

    /// The block clip waits on the stranger's line until the user reports it, and the block, which the report makes, stops
    /// the stranger's next post where the engine would, while Sam's still lands.
    @Test func theBlockClipWaitsForTheReportAndTheBlockStopsTheStranger() async throws {
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 100_000_000, scene: .block)
        let stranger = try #require(DemoSeed.nodeId(.stranger))
        let director = try #require(Self.director(of: .block, over: stores, me: identity.nodeId))
        let session = Self.session(stores, identity: identity, director: director, scene: .block)
        let listening = Task { await session.listen() }
        await session.start()
        let chat = ChatModel(conversationId: Conversations.nearby, session: session)
        let following = Task { await chat.appear() }
        while stores.messages.message("block-1") == nil {
            await Task.yield()
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        #expect(stores.messages.message("block-2") == nil && stores.messages.message("block-3") == nil, "the script waits for the block")

        await session.report(AbuseReport(person: stranger, name: "", place: .room, messageId: "block-1"))
        while stores.messages.message("block-3") == nil {
            await Task.yield()
        }
        #expect(stores.blocks.blockedNodeIds() == [stranger])
        #expect(stores.messages.message("block-1") == nil, "the report deleted the line")
        #expect(stores.messages.message("block-2") == nil, "the block stopped the stranger's next post")
        following.cancel()
        listening.cancel()
    }

    /// `scene`'s director over `stores`, with no pause between cues and a byte or two for each photo.
    private static func director(of scene: DemoScene, over stores: MeshStores, me: NodeId) -> DemoDirector? {
        DemoDirector(
            scene: scene,
            stores: stores,
            me: me,
            snap: { _ in [0xFF, 0xD8] },
            now: { 100_000_000 },
            wait: { _ in await Task.yield() }
        )
    }

    /// A session over a real mesh on the demo's radio, showing `scene`'s linked peers, with `director` playing.
    private static func session(
        _ stores: MeshStores, identity: IdentityKeys, director: DemoDirector, scene: DemoScene = .trailer
    ) -> AppSession {
        let node = Mesh(
            identity: identity,
            deviceTag: nil,
            stores: stores,
            radio: DemoRadio(state: .on),
            clock: DemoClock(),
            random: SystemRandomNumberGenerator()
        )
        let mesh = DemoMesh(node, linked: DemoSeed.linked(in: scene), director: director)
        let session = AppSession(identity: OwnIdentity(bundle: identity.bundle), stores: stores, mesh: mesh)
        session.director = director
        return session
    }
}
