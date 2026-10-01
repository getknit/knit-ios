import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitWire
import Testing

/// A group made, used, renamed and left over the control lines, against a second engine (ADR 2026-09.n393).
extension PeerNodeTests {
    @Test func aGroupIsMadeSentRenamedAndLeftOverTheControlLines() async throws {
        let rig = PeerRig()
        await rig.node.start(name: "Near")
        try await rig.link()
        rig.farEngine.start()
        rig.farEngine.linkUp(Neighbor(nodeId: rig.keys.nodeId, capabilities: .local))
        rig.deliverFromFar()
        _ = try #require(await rig.lines.first { $0["event"] as? String == "profile" })
        rig.deliverToFar()

        let made = try await rig.send(#"{"cmd":"group-create","members":["\#(rig.far.nodeId)"]}"#)
        let groupId = try #require(made["id"] as? String)
        #expect(made["members"] as? [String] == [rig.far.nodeId.string, rig.keys.nodeId.string])
        let sent = try await rig.send(#"{"cmd":"group-send","conv":"\#(groupId)","text":"hi pair"}"#)
        #expect(sent["pendingKey"] as? Bool == false)
        rig.deliverToFar()
        #expect(rig.farEngine.stores.messages.messages(in: groupId).contains { $0.body == "hi pair" })

        rig.farEngine.sendGroupMessage("hi back", to: groupId)
        rig.deliverFromFar()
        let reply = try #require(await rig.lines.first { $0["event"] as? String == "message" && $0["conv"] as? String == groupId })
        #expect(reply["body"] as? String == "hi back")
        #expect(reply["request"] as? Bool == false, "a group we made is ours")
        #expect(reply["kind"] as? Int == 0)

        let renamed = try await rig.send(#"{"cmd":"group-rename","conv":"\#(groupId)","name":"Pair"}"#)
        #expect(renamed["name"] as? String == "Pair")
        rig.deliverToFar()
        #expect(rig.farEngine.stores.groups.group(groupId)?.name == "Pair")
        let thread = try await rig.send(#"{"cmd":"messages","conv":"\#(groupId)"}"#)
        let kinds = try #require(thread["messages"] as? [[String: Any]]).map { $0["kind"] as? Int }
        #expect(kinds.first == MessageKind.groupCreated.rawValue, "the created line leads the thread")

        let left = try await rig.send(#"{"cmd":"group-leave","conv":"\#(groupId)"}"#)
        #expect(left["conv"] as? String == groupId)
        rig.deliverToFar()
        #expect(rig.farEngine.stores.groups.group(groupId)?.departed == [rig.keys.nodeId.string])
        let changed = try #require(await rig.lines.first { $0["event"] as? String == "group" && $0["left"] as? Bool == true })
        #expect(changed["id"] as? String == groupId)
    }
}
