public import KnitWire

/// A frame carried for store-and-forward (`CarriedFrame` in knit-next's `ForwardStore.kt`): the decoded routing
/// envelope, plus the originator's exact bytes and their signature.
///
/// The routing counters are never stored. A re-served frame goes out in a fresh ``WireEnvelope`` around
/// ``signed`` and ``sig`` (``reserved``), so it floods again with a full hop budget; the signature covers
/// neither `ttl` nor `hops`.
public struct CarriedFrame: Sendable, Equatable {
    /// The decoded envelope, read for routing and bucketing. Never re-encoded.
    public var envelope: RelayEnvelope
    /// The Ed25519 signature over ``signed``.
    public var sig: [UInt8]
    /// The originator's envelope bytes, byte for byte.
    public var signed: [UInt8]

    /// Makes a carried frame.
    public init(envelope: RelayEnvelope, sig: [UInt8], signed: [UInt8]) {
        self.envelope = envelope
        self.sig = sig
        self.signed = signed
    }

    /// The frame as a custody re-serve sends it (`ForwardSync.onDigest`): `ttl` 8, `hops` 0 and flooded, around
    /// the verbatim bytes.
    public var reserved: WireEnvelope { WireEnvelope(sig: sig, signed: signed) }
}

/// Who put a frame into custody (`ForwardStore.ORIGIN_*`). Diagnostic only: our own frames count against the
/// same quotas as everyone else's, so every node keeps the same newest-N set.
public enum CustodyOrigin: Sendable, Equatable {
    /// A frame relayed for someone else.
    case relayed
    /// A frame this node originated, its own profile included.
    case own
}
