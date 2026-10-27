import KnitMesh
import KnitWire
import Testing

/// What the actor reports processed to the radio, in a file of their own so ``MeshTests`` stays in bounds: every
/// delivery, running or not, or a radio bounding its channels would wait on a count that never falls (ADR 2026-10.f5zs).
extension MeshTests {
    @Test func everyDeliveryIsReportedConsumedOnItsChannel() async {
        let rig = rig()
        await rig.mesh.start()
        await linkBob(rig)
        let undecodable = LinkRecord(.frame, payload: [0xFF]).encoded ?? []
        await rig.mesh.process(.received(channel, undecodable))
        await rig.mesh.process(.received(channel, []))
        await rig.mesh.process(.received(ChannelID(77), [1, 2, 3]))
        #expect(
            rig.radio.consumed == [
                .init(count: hello(bob).count, channel: channel),
                .init(count: undecodable.count, channel: channel),
                .init(count: 0, channel: channel),
                .init(count: 3, channel: ChannelID(77)),
            ],
            "a record that does not decode, an empty read and a channel the links never knew are all reported")
    }

    @Test func aStoppedMeshStillReportsWhatItWasHanded() async {
        let rig = rig()
        await rig.mesh.process(.received(channel, [9]))
        await rig.mesh.start()
        await linkBob(rig)
        await rig.mesh.stop()
        await rig.mesh.process(.received(channel, [1, 2]))
        #expect(rig.radio.consumed.map(\.count) == [1, hello(bob).count, 2], "before start and after stop too")
    }

    @Test func theRadiosOwnStreamIsReportedConsumed() async {
        let rig = rig()
        await rig.mesh.start()
        rig.radio.emit(.accepted(channel))
        rig.radio.emit(.received(channel, hello(bob)))
        for await event in rig.mesh.events {
            if case .neighborsChanged(let neighbors) = event, !neighbors.isEmpty {
                break
            }
        }
        // The event is said inside the HELLO's turn on the actor, and the report goes at its end: a call waits for it.
        #expect(await rig.mesh.isRunning)
        #expect(rig.radio.consumed == [.init(count: hello(bob).count, channel: channel)])
    }
}
