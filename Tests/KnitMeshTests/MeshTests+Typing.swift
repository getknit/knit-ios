import KnitMesh
import KnitStore
import KnitWire
import Testing

/// Typing cues through the actor, in a file of their own so ``MeshTests`` stays in bounds.
extension MeshTests {
    /// The next picture of who is typing the mesh announces.
    private func nextTyping(in events: inout AsyncStream<MeshEvent>.Iterator) async -> [String: [NodeId]]? {
        while let event = await events.next() {
            if case .typing(let picture) = event {
                return picture
            }
        }
        return nil
    }

    @Test func aCueLapsesOnTheTimerWithNoFrameToWakeIt() async throws {
        let rig = rig()
        var events = rig.mesh.events.makeAsyncIterator()
        await rig.mesh.start()
        await linkBob(rig)
        let profile = try bob.profile(publishedAt: EngineFixture.start)
        await rig.mesh.process(.received(channel, LinkRecord(.frame, payload: profile.wire.encoded).encoded ?? []))
        let cue = try bob.typing(id: "t-1")
        await rig.mesh.process(.received(channel, LinkRecord(.frame, payload: cue.wire.encoded).encoded ?? []))
        #expect(await nextTyping(in: &events) == [Conversations.nearby: [bob.nodeId]])
        #expect(await rig.mesh.typing == [Conversations.nearby: [bob.nodeId]])
        // Whatever deadline the timer sleeps on, the first to wake finds the cue due.
        rig.clock.advance(12_000)
        #expect(await nextTyping(in: &events)?.isEmpty == true)
    }

    @Test func stoppingForgetsWhoIsTypingAndOurCueGoesOutOverTheLink() async throws {
        let rig = rig()
        var events = rig.mesh.events.makeAsyncIterator()
        await rig.mesh.start()
        await linkBob(rig)
        #expect(await rig.mesh.noteTyping(in: Conversations.nearby))
        #expect(rig.radio.frames(on: channel).compactMap { try? RelayEnvelope(decoding: $0.signed).type }.contains(.typing))
        let profile = try bob.profile(publishedAt: EngineFixture.start)
        await rig.mesh.process(.received(channel, LinkRecord(.frame, payload: profile.wire.encoded).encoded ?? []))
        let cue = try bob.typing(id: "t-1")
        await rig.mesh.process(.received(channel, LinkRecord(.frame, payload: cue.wire.encoded).encoded ?? []))
        #expect(await nextTyping(in: &events) == [Conversations.nearby: [bob.nodeId]])
        await rig.mesh.stop()
        #expect(await nextTyping(in: &events)?.isEmpty == true)
        #expect(await rig.mesh.typing.isEmpty)
    }
}
