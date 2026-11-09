import KnitCrypto
import KnitMesh
import KnitPeer
import KnitTestSupport
import KnitWire
import Testing

/// knit-peer's two wrappers sit above the seal (the `link-seal` contract's T5 and T6): the KEY_SHARE, the sealer and a
/// plain dial's no-reply pass to the radio under them as they came, so what they lie or flood is sealed below.
@Suite struct WrapperSealTests: LyingRadioFixture {
    private static func sealer() throws -> LinkSealer {
        let ours = LinkSeal.Ephemeral()
        return try LinkSeal.derive(ours, peerShare: LinkSeal.Ephemeral().keyShare, role: .dialer).sealer
    }

    private let share = [UInt8](repeating: 0x5E, count: 37)
    private let channel = ChannelID(5)

    @Test func theLyingRadioPassesTheSealOnUntouched() throws {
        let inner = CallRadio()
        let radio = lying(inner)
        radio.writeKeyShare(share, sealer: nil, to: channel)
        radio.seal(channel, with: try Self.sealer())
        radio.dialGotNoReply(at: RadioAddress("far"))
        #expect(inner.calls == [.keyShare(channel, share, sealed: false), .sealed(channel), .noReply(RadioAddress("far"))])
    }

    @Test func theFloodPassesTheSealOnUntouched() throws {
        let inner = CallRadio()
        let flood = FloodRadio(wrapping: inner, bytesPerSecond: 1)
        flood.writeKeyShare(share, sealer: try Self.sealer(), to: channel)
        flood.seal(channel, with: try Self.sealer())
        flood.dialGotNoReply(at: RadioAddress("far"))
        #expect(inner.calls == [.keyShare(channel, share, sealed: true), .sealed(channel), .noReply(RadioAddress("far"))])
    }
}
