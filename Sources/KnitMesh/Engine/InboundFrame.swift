public import KnitWire

/// A frame off a link (`InboundFrame` in knit-next's `MeshTransport.kt`): the frame as received, its decoded
/// envelope, and the neighbour it came from. The wire's `sig` and `signed` are forwarded byte for byte on relay.
public struct InboundFrame: Sendable, Equatable {
    /// The frame as received.
    public var wire: WireEnvelope
    /// Its decoded envelope.
    public var envelope: RelayEnvelope
    /// The neighbour it arrived from.
    public var from: NodeId

    /// Makes an inbound frame.
    public init(wire: WireEnvelope, envelope: RelayEnvelope, from: NodeId) {
        self.wire = wire
        self.envelope = envelope
        self.from = from
    }
}
