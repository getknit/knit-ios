import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// knit-peer's seal switch through the actor (the `link-seal` contract's T5): it reads back as set, and the advert follows
/// it at once, `FLAG_LINK_SEAL` gone with the seal.
@Suite(.timeLimit(.minutes(1))) struct MeshSealSwitchTests {
    @Test func theSwitchReadsBackAndTheAdvertFollowsIt() async {
        let radio = FakeRadio(advertisesServiceData: false)
        let mesh = Mesh(
            identity: TestPeer(seed: 1).keys,
            deviceTag: nil,
            stores: MeshStores.inMemory(),
            radio: radio,
            clock: ManualClock(wall: EngineFixture.start, monotonic: 1000),
            random: SeededGenerator(seed: 5)
        )
        await mesh.start()
        await mesh.process(.listening(psm: 0x81))
        #expect(await mesh.sealSwitch == .on)
        #expect(radio.advertised.last.map { $0.flags & AdvertPayload.linkSealFlag != 0 } == true)
        await mesh.setSealSwitch(.off)
        #expect(await mesh.sealSwitch == .off)
        #expect(radio.advertised.last.map { $0.flags & AdvertPayload.linkSealFlag == 0 } == true, "the flag goes with the bit")
    }

    /// What each switch does, at a glance: who claims the bit, who airs the flag, who dials and answers sealed, and whose
    /// responder refuses a plain link between sealing builds.
    @Test func eachSwitchSaysWhatItDoes() {
        let rows = LinkManager.SealSwitch.allCases.map { seal in
            [seal.claimsBit, seal.advertisesFlag, seal.dialsSealed, seal.answersSealed, seal.refusesPlainAsResponder]
        }
        #expect(LinkManager.SealSwitch.allCases == [.on, .off, .downgrade, .plainReply])
        #expect(
            rows == [
                [true, true, true, true, true],
                [false, false, false, false, true],
                [true, false, false, true, false],
                [true, true, true, false, true],
            ])
    }
}
