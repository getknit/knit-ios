import KnitMesh
import KnitStore
import KnitWire
import Testing

/// The app's group calls through the actor (ADR 2026-09.n393), in a file of their own so ``MeshTests`` stays in
/// bounds.
extension MeshTests {
    @Test func theAppsGroupCallsGoOutOverTheLinks() async throws {
        let rig = rig()
        await rig.mesh.start()
        await linkBob(rig)
        let profile = try bob.profile(publishedAt: EngineFixture.start)
        await rig.mesh.process(.received(channel, LinkRecord(.frame, payload: profile.wire.encoded).encoded ?? []))
        #expect(await rig.mesh.createGroup(with: []) == nil, "a group needs someone else")
        let group = try #require(await rig.mesh.createGroup(with: [bob.nodeId, TestPeer(seed: 3).nodeId]))
        let message = try #require(await rig.mesh.sendGroupMessage("Hi all", to: group.id))
        #expect(await rig.mesh.renameGroup(group.id, to: "Hikers")?.name == "Hikers")
        #expect(await rig.mesh.leaveGroup(group.id))
        let sent = rig.radio.frames(on: channel).compactMap { try? RelayEnvelope(decoding: $0.signed) }
        #expect(sent.contains { $0.id == message.id && $0.group?.id == group.id })
        #expect(sent.contains { $0.type == .groupUpdate && $0.group?.name == "Hikers" })
        #expect(sent.contains { $0.type == .groupLeave })
        #expect(rig.stores.groups.group(group.id)?.hasLeft == true)
    }
}
