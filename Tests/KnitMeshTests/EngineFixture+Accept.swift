import KnitMesh
import KnitStore
import KnitWire

extension EngineFixture {
    /// Accepts each of `peers`' DM threads in the store alone, as a user's accept long ago left it: their DMs' photos are
    /// fetched and kept, and so are those of the groups and the room posts they write in (knit-ios #21). Nothing is wanted
    /// or sent now, as ``MeshEngine/accept(_:)`` would.
    func befriend(_ peers: TestPeer...) {
        for peer in peers {
            stores.conversations.accept(peer.nodeId.string)
        }
    }
}
