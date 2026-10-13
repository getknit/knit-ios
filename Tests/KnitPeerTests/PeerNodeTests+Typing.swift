import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitWire
import Testing

/// Typing cues both ways over the control lines, against a second engine, as `interop.py iphone-typing` drives a phone.
extension PeerNodeTests {
    @Test func aFarPeersCueIsAnEventLineAndOursReachesThem() async throws {
        let rig = PeerRig()
        await rig.node.start(name: "Near")
        try await rig.link()
        rig.farEngine.start()
        rig.farEngine.linkUp(Neighbor(nodeId: rig.keys.nodeId, capabilities: .local))
        rig.deliverFromFar()
        _ = try #require(await rig.lines.first { $0["event"] as? String == "profile" })
        rig.deliverToFar()

        #expect(rig.farEngine.noteTyping(in: Conversations.nearby))
        rig.deliverFromFar()
        let line = try #require(await rig.lines.first { $0["event"] as? String == "typing" })
        #expect(line["typing"] as? [String: [String]] == ["nearby": [rig.far.nodeId.string]])
        let status = try await rig.send(#"{"cmd":"status"}"#)
        #expect(status["typing"] as? [String: [String]] == ["nearby": [rig.far.nodeId.string]])

        let sent = try await rig.send(#"{"cmd":"typing","to":"\#(rig.far.nodeId)"}"#)
        #expect(sent["sent"] as? Bool == true)
        rig.deliverToFar()
        #expect(rig.farEngine.typingNow == [rig.keys.nodeId.string: [rig.keys.nodeId]])
    }
}
