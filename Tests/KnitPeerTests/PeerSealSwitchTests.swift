import KnitMesh
import KnitPeer
import KnitWire
import Testing

/// `--seal off` (the `link-seal` contract's T5): set before the start, the node's reply HELLO carries no seal's bit, as
/// Android v2.11.0's does.
@Suite(.timeLimit(.minutes(1))) struct PeerSealSwitchTests {
    @Test func theSealSwitchTakesTheBitOutOfTheReply() async throws {
        let rig = PeerRig()
        await rig.node.setSealSwitch(.off)
        await rig.node.start(name: nil)
        try await rig.link()
        let reply = try #require(rig.radio.records(on: PeerRig.channel).first { $0.tag == .hello })
        let capabilities = Hello(payload: reply.payload).capabilities
        #expect(capabilities.contains(.linkProof) && !capabilities.contains(.linkSeal))
    }
}
