import KnitCrypto
import KnitMesh
import Testing

@testable import KnitAppCore

/// The demo's radio holds no channel, so the seal's calls change nothing on it: no level, no event.
@Suite struct DemoRadioSealTests {
    @Test func theDemoRadioTakesTheSealsCallsAndHoldsNothing() throws {
        let radio = DemoRadio(state: .on)
        let channel = ChannelID(3)
        let sealer = try LinkSeal.derive(LinkSeal.Ephemeral(), peerShare: LinkSeal.Ephemeral().keyShare, role: .dialer).sealer
        radio.writeKeyShare([UInt8](repeating: 1, count: 37), sealer: sealer, to: channel)
        radio.seal(channel, with: sealer)
        #expect(radio.outboxLevel(on: channel) == OutboxLevel())
    }
}
