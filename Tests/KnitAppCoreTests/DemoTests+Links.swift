import KnitCrypto
import KnitMesh
import KnitStore
import Testing

@testable import KnitAppCore

// Links (ADR 2026-11.w5ew), apart from the suite's body for the same reason as its mentions.
extension DemoTests {
    /// The other Sam's room post and our last DM to Sam each carry a link, so the UI walks of the room and the DM audit one
    /// in someone else's bubble and one in ours.
    @Test func theDemoCarriesALinkInEachBubble() throws {
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 10_000_000, scene: .edgeCases)
        let theirs = try #require(stores.messages.message("room-2"))
        let ours = try #require(stores.messages.message("dm-3"))
        #expect(LinkText.links(in: theirs.body).map(\.url) == ["https://festival.example/map"])
        #expect(LinkText.links(in: ours.body).map(\.url) == ["https://www.festival.example/gates"])
    }
}
