import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// The ratchet through the actor that runs the engine and the link manager on a radio (ADR 2026-10.5sk9).
@Suite(.timeLimit(.minutes(1))) struct MeshRatchetTests {
    let alice = TestPeer(seed: 1)
    let bob = TestPeer(seed: 2)
    let channel = ChannelID(50)

    /// The control surface's reset is flooded and carried as our own, so it settles the mesh as every other send does:
    /// the advert's digest cue moves with it (phase P5a, the blobs review).
    @Test func aForcedResetMovesTheAdvertsDigestCue() async throws {
        let radio = FakeRadio(advertisesServiceData: false)
        let clock = ManualClock(wall: EngineFixture.start, monotonic: 1000)
        let stores = MeshStores.inMemory()
        let mesh = Mesh(
            identity: alice.keys,
            prekeys: try PrekeyRing.load(for: alice.keys, from: KeptSecretStore(alice.keys.storedForm)),
            deviceTag: nil,
            stores: stores,
            radio: radio,
            clock: clock,
            random: SeededGenerator(seed: 11),
            configuration: MeshConfiguration(ratchet: true),
            log: RecordingLog()
        )
        await mesh.start()
        await mesh.process(.listening(psm: 0x81))
        await mesh.process(.accepted(channel))
        let hello = LinkRecord(.hello, payload: Hello(nodeId: bob.nodeId.string, capabilities: 0xFFF).payload).encoded ?? []
        await mesh.process(.received(channel, hello))
        let profile = try AndroidPeer(bob).profile(publishedAt: EngineFixture.start)
        await mesh.process(.received(channel, LinkRecord(.frame, payload: profile.wire.encoded).encoded ?? []))
        let debounce = LinkManager.Configuration().advertDebounceMilliseconds
        clock.advance(debounce)
        await mesh.fireDueTimers()
        let before = UInt32(truncatingIfNeeded: stores.custody.fingerprint(now: clock.wallMilliseconds()))
        #expect(radio.advertised.last?.digestCue == before)

        guard case .sent = await mesh.sendRatchetReset(to: bob.nodeId) else {
            Issue.record("the reset goes")
            return
        }
        let after = UInt32(truncatingIfNeeded: stores.custody.fingerprint(now: clock.wallMilliseconds()))
        #expect(after != before, "carried as our own")
        clock.advance(debounce)
        await mesh.fireDueTimers()
        #expect(radio.advertised.last?.digestCue == after)
    }
}
