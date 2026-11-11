import KnitCrypto
import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// A transport that airs no tag takes ``MeshTransport``'s defaults for our presence keys (ADR 2026-11.prsp): our key reaches it
/// and changes nothing it does, as knit-peer's test transports rely on.
@Suite struct CapturingTransportTests {
    @Test func aTransportThatAirsNoTagIgnoresOurPresenceKey() throws {
        let transport = CapturingTransport(peer: fixtureNodeId(8))
        let key = try #require(PresenceKey(bytes: [UInt8](repeating: 1, count: PresenceKey.byteCount)))
        transport.ownPresenceKeyChanged(OwnPresenceKey(generation: 1, key: key))
        transport.ownPresenceKeyChanged(nil)
        #expect(transport.sent.isEmpty)
        #expect(transport.neighbors.count == 1)
    }
}
