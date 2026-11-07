import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The presence keys end to end through the actor (ADR 2026-11.sv5t): an Android contact seals a ctl 11 over the ratchet,
/// point to point over its link, the iPhone's engine stores it and lists it to its own link manager at the settle that
/// follows, and the contact's blinded advert then resolves by key, with no link (`PresenceKeyLabTest`'s recognition, at
/// knit-next `cad69c77b`).
@Suite(.timeLimit(.minutes(1))) struct MeshPresenceKeyTests {
    private let me = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let channel = ChannelID(50)

    private func record(_ frame: TestFrame) -> [UInt8] {
        LinkRecord(.frame, payload: frame.wire.encoded).encoded ?? []
    }

    @Test func aContactsKeyReachesTheRadioAndItsTagResolvesByKey() async throws {
        let radio = FakeRadio(advertisesServiceData: false)
        let clock = ManualClock(wall: EngineFixture.start, monotonic: 1000)
        let stores = MeshStores.inMemory()
        let keychain = KeptSecretStore(me.keys.storedForm)
        let mesh = Mesh(
            identity: me.keys,
            prekeys: try PrekeyRing.load(for: me.keys, from: keychain),
            deviceTag: nil,
            stores: stores,
            radio: radio,
            clock: clock,
            random: SeededGenerator(seed: 11),
            configuration: MeshConfiguration(ratchet: true),
            log: RecordingLog()
        )
        await mesh.start()
        // Our prekey as Bob pins it from our profile: the one the engine's start minted into the keychain.
        let newest = try #require(try PrekeyRing.load(for: me.keys, from: keychain).newest)
        let prekey = try #require(PeerPrekey(verifying: newest.info, signedBy: me.keys.bundle))

        let android = try AndroidPeer(bob)
        let blinding = BlindingPeer(bob.nodeId)
        await mesh.process(.accepted(channel))
        let hello = Hello(nodeId: bob.nodeId.string, capabilities: Capabilities(rawValue: AndroidPeer.capabilities)).payload
        await mesh.process(.received(channel, LinkRecord(.hello, payload: hello).encoded ?? []))
        await mesh.process(.received(channel, record(try android.profile(publishedAt: EngineFixture.start))))
        await mesh.accept(bob.nodeId.string)
        let content = PresenceKeyFrame.content([(generation: EngineFixture.start, key: blinding.key.bytes)])
        let frame = try android.dm(content, to: me, prekey: prekey, id: frameIdOf("pk-mesh"), sentAt: EngineFixture.start, relay: false)
        await mesh.process(.received(channel, record(frame)))
        #expect(stores.presenceKeys.keys(of: bob.nodeId).map(\.held.key) == [blinding.key])
        #expect(await mesh.presenceKeyCounts.stored == 1)

        // Bob's advert, blinded under that key and his id, from an address we never linked on.
        var away = blinding
        away.address = RadioAddress("addr-away")
        await mesh.process(.sighted(away.sighting(away.tag(wall: clock.wallMilliseconds()))))
        #expect(await mesh.aliasCounters.resolvedByKey == 1)
        // The tag minted under the same key as another's id is no tag of Bob's.
        let forged = BlindingPeer(TestPeer(seed: 3).nodeId)
        await mesh.process(.sighted(forged.sighting(forged.tag(wall: clock.wallMilliseconds()))))
        #expect(await mesh.aliasCounters.resolvedByKey == 1)
    }
}
