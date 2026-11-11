import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The writer through the `Mesh` actor (ADR 2026-11.prsp): the system's clock-change notification makes the links read the
/// wall clock again, so a clock set back below the slot on the air rotates at once; the runtime switch reaches the links.
@Suite(.timeLimit(.minutes(1))) struct MeshBlindWriterTests {
    private let me = TestPeer(seed: 1)

    /// A clock-change name of this suite's own, so its post reaches no other mesh running in the process.
    private static let clockChange = "knit.test.clockChange.\(UInt64.random(in: 0 ... .max))"

    private func mesh(_ radio: FakeRadio, _ clock: ManualClock) -> Mesh {
        var links = LinkManager.Configuration()
        links.blindsAdvert = true
        links.clockChangeName = Self.clockChange
        return Mesh(
            identity: me.keys,
            deviceTag: nil,
            stores: MeshStores.inMemory(),
            radio: radio,
            clock: clock,
            random: SeededGenerator(seed: 5),
            linkConfiguration: links
        )
    }

    /// Waits until the radio has been handed `count` adverts.
    private func adverts(_ radio: FakeRadio, reach count: Int) async {
        for await activity in radio.activity {
            if case .advertised = activity, radio.advertised.count >= count {
                return
            }
        }
    }

    @Test func aClockSetBackRotatesAtOnceWhenTheSystemSaysItWasSet() async throws {
        let radio = FakeRadio(advertisesServiceData: false)
        let clock = ManualClock(wall: EngineFixture.start, monotonic: 1000)
        let mesh = mesh(radio, clock)
        await mesh.start()
        await mesh.process(.listening(psm: 0x81))
        // Whatever is due now runs first, so the only wake left is the turn's edge, which the hand-moved clock never reaches.
        await mesh.fireDueTimers()
        #expect(radio.advertised.count == 1)
        let first = try #require(radio.advertised.last)
        #expect(first.blinded)
        clock.setWall(EngineFixture.start - 2 * 3_600_000)
        NotificationCenter.default.post(name: Notification.Name(Self.clockChange), object: nil)
        await adverts(radio, reach: 2)
        let now = try #require(radio.advertised.last)
        #expect(now.blinded)
        #expect(now.advertised != first.advertised)
        // Stopped, the mesh hears no clock: the next start reads it anyway.
        await mesh.stop()
        await mesh.wallClockChanged()
        #expect(radio.advertised.count == 2)
    }

    @Test func theSwitchReachesTheLinks() async {
        let radio = FakeRadio(advertisesServiceData: false)
        let clock = ManualClock(wall: EngineFixture.start, monotonic: 1000)
        let mesh = mesh(radio, clock)
        await mesh.start()
        await mesh.process(.listening(psm: 0x81))
        #expect(radio.advertised.last?.blinded == true)
        await mesh.setBlinding(false)
        #expect(radio.advertised.last?.blinded == false)
        #expect(radio.advertised.last?.advertised == me.nodeId)
        await mesh.stop()
    }
}
