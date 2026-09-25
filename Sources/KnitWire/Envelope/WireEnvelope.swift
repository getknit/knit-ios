/// Layer 1, the unit on the radio (`WireEnvelope` in knit-next's `Wire.kt`).
///
/// It carries the mutable routing counters and the signature over ``signed``, the originator's exact
/// ``RelayEnvelope`` bytes. A relay rewrites only ``ttl`` and ``hops`` (``relayed()``); ``sig`` and ``signed``
/// pass through untouched, so every verifier checks the bytes the originator signed. Never decode and
/// re-encode ``signed``.
public struct WireEnvelope: CBORRepresentable, Equatable {
    /// knit-next's `DEFAULT_TTL`: the most hops a frame travels, whatever its sender asks for.
    public static let defaultTTL = 8

    /// The hop limit. Attacker-controlled, so a relay caps it at ``defaultTTL``.
    public var ttl: Int
    /// How many hops the frame has made.
    public var hops: Int
    /// Whether routers flood it onward. `false` marks point-to-point control frames.
    public var relay: Bool
    /// The Ed25519 signature over ``signed``: 64 bytes, or empty for the two unsigned forms.
    public var sig: [UInt8]
    /// The originator's encoded ``RelayEnvelope``, forwarded byte for byte.
    public var signed: [UInt8]

    /// Makes an envelope; the defaults are a fresh flooded frame's.
    public init(ttl: Int = Self.defaultTTL, hops: Int = 0, relay: Bool = true, sig: [UInt8], signed: [UInt8]) {
        self.ttl = ttl
        self.hops = hops
        self.relay = relay
        self.sig = sig
        self.signed = signed
    }

    /// Reads an envelope from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "WireEnvelope")
        ttl = try fields.optional("ttl", .int32) ?? Self.defaultTTL
        hops = try fields.optional("hops", .int32) ?? 0
        relay = try fields.optional("relay", .bool) ?? true
        sig = try fields.required("sig", .bytes)
        signed = try fields.required("signed", .bytes)
    }

    /// The envelope as an item, defaults omitted.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.int("ttl", ttl, default: Self.defaultTTL)
        writer.int("hops", hops, default: 0)
        writer.bool("relay", relay, default: true)
        writer.bytes("sig", sig)
        writer.bytes("signed", signed)
        return writer.cbor
    }

    /// The copy a relay forwards: ``ttl`` capped at ``defaultTTL`` and ``hops`` incremented, with ``sig`` and
    /// ``signed`` reused as they are.
    public func relayed() -> Self {
        Self(ttl: min(ttl, Self.defaultTTL), hops: hops + 1, relay: relay, sig: sig, signed: signed)
    }
}
