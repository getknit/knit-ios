import Foundation
import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// Blocking over the control lines (ADR 2026-10.5wgg): what `interop.py iphone-block` sends, and what it reads back.
@Suite(.timeLimit(.minutes(1))) struct MeshControlBlockTests {
    /// Through the mesh, `block` and `unblock` change what `peers` and a `profile` event say.
    @Test func peersAndProfilesSayWhoIsBlocked() async throws {
        let rig = ControlRig()
        let blocked = fixtureNodeId(9)
        let other = fixtureNodeId(8)
        for id in [blocked, other] {
            rig.stores.peers.upsert(PeerRecord(nodeId: id, name: "", status: "", publicKey: "", updatedAt: 1))
        }
        let reply = try await rig.send(#"{"cmd":"block","peer":"\#(blocked)"}"#)
        #expect(reply["peer"] as? String == blocked.string && reply["ok"] as? Bool == true)
        let peers = try #require(try await rig.send(#"{"cmd":"peers"}"#)["peers"] as? [[String: Any]])
        #expect(peers.compactMap { $0["blocked"] as? Bool } == [false, true])
        let profile = try #require(try await rig.report(.peerUpdated(blocked)).first)
        #expect(profile["blocked"] as? Bool == true)
        _ = try await rig.send(#"{"cmd":"unblock","peer":"\#(blocked)"}"#)
        #expect(try await rig.report(.peerUpdated(blocked)).first?["blocked"] as? Bool == false)
        #expect(rig.stores.blocks.blockedNodeIds().isEmpty)
    }
}
