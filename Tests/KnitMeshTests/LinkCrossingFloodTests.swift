import KnitMesh
import KnitWire
import Testing

/// A neighbour's inbound flood cannot buy back a write the link already carried: inbound stamps are kept apart from
/// outbound ones (``LinkCrossings``, ADR 2026-10.f5zs).
@Suite struct LinkCrossingFloodTests {
    private let low = LinkRig.low
    private let high = LinkRig.high

    /// A decodable signed frame whose key, the first eight signature bytes, is `index`'s own.
    private static func junk(_ index: Int) -> WireEnvelope {
        let envelope = RelayEnvelope(type: .chat, id: "junk\(index)", senderId: LinkRig.low.string, payload: [])
        let tail = [24, 16, 8, 0].map { UInt8(index >> $0 & 0xFF) }
        return WireEnvelope(sig: [0xEE, 0xEE, 0xEE, 0xEE] + tail + Array(repeating: 0, count: 56), signed: envelope.encoded)
    }

    @Test func a1025FrameInboundFloodLeavesNoFrameWrittenTwiceInsideTheWindow() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        let ours = (1...8).map { LinkRig.signedFrame("ours\($0)", sig: UInt8($0)) }
        for frame in ours {
            rig.links.send(frame, to: nil)
        }
        #expect(rig.radio.frames(on: ChannelID(100)) == ours)
        for index in 0..<1025 {
            rig.clock.advance(100)
            #expect(rig.handle(.received(ChannelID(100), LinkRig.frameRecord(Self.junk(index)))).count == 1)
        }
        #expect(rig.links.neighbors.count == 1, "the link stays up")
        for frame in ours {
            rig.links.send(frame, to: nil)
            rig.links.send(frame, to: low)
        }
        #expect(rig.radio.frames(on: ChannelID(100)) == ours, "102.5 s on, inside 10 minutes, nothing goes twice")
        #expect(rig.links.crossingCount == ours.count + LinkCrossings<ChannelID>.defaultMaxPerLink)
    }
}
